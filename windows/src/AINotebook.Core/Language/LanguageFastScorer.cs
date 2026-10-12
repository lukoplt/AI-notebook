namespace AINotebook.Core.Language;

/// <summary>The decision fields of <see cref="LanguageTextResult"/>, computed by <see cref="LanguageFastScorer"/>
/// without the diagnostics. <c>CombinedScores</c> follows the model's profile order.</summary>
internal sealed record LanguageTextDecision(string Label, string Reason, long LetterCount, long WordCount, string Winner,
    string RunnerUp, long Margin, long CoverageBp, long[] CombinedScores);

/// <summary>
/// Label-only scoring for ingestion: the same arithmetic as <see cref="LanguageScorer.Score"/> on n-gram occurrences
/// instead of counted, sorted feature lists. A weighted sum over distinct features (count × weight) equals the sum over
/// their occurrences, so every order score, combined score, margin, coverage and decision is identical
/// (<c>LanguageFastScorerTests</c> checks this against the full scorer). Model tables are flattened once per scorer: one
/// open-addressing table per order maps a packed n-gram to its vocabulary index, and weights are stored feature-major
/// so one lookup updates every profile.
/// </summary>
internal sealed class LanguageFastScorer
{
    private sealed class Order(ulong[] keys, int[] indices, long[] weights, long[] unknownWeights)
    {
        public readonly ulong[] Keys = keys;
        public readonly int[] Indices = indices;
        public readonly int Mask = keys.Length - 1;
        public readonly long[] Weights = weights;          // vocabulary index * profileCount + profile
        public readonly long[] UnknownWeights = unknownWeights;

        public int Find(ulong key)
        {
            int slot = Slot(key, Mask);
            while (true)
            {
                ulong stored = Keys[slot];
                if (stored == key) return Indices[slot];
                if (stored == Empty) return -1;
                slot = (slot + 1) & Mask;
            }
        }
    }

    private const ulong Empty = ulong.MaxValue;
    private readonly LanguageModel _model;
    private readonly UnicodeTables _tables;
    private readonly Order[] _orders;
    private readonly int _profileCount;
    private readonly string[] _profileIds;
    private readonly long[] _priors, _orderWeights;
    /// <summary>Position of each profile in the full scorer's tie order (background first, then ordinal id).</summary>
    private readonly int[] _tieRanks;

    /// <summary>Symbols (-2 EOS, -1 BOS, scalars) packed into 21 bits each.</summary>
    internal static ulong Symbol(int value) => (ulong)(value + 2);
    internal static ulong Key(IReadOnlyList<int> symbols)
    {
        ulong key = 0;
        foreach (int symbol in symbols) key = key << 21 | Symbol(symbol);
        return key;
    }
    private static int Slot(ulong key, int mask) => (int)((key * 0x9E3779B97F4A7C15UL) >> 32) & mask;

    internal LanguageFastScorer(LanguageModel model, UnicodeTables tables)
    {
        _model = model;
        _tables = tables;
        var profiles = model.Profiles;
        _profileCount = profiles.Length;
        _profileIds = profiles.Select(p => p.Id).ToArray();
        _priors = profiles.Select(p => p.PriorWeight).ToArray();
        _orderWeights = model.Parameters.OrderWeights.ToArray();
        var ranked = Enumerable.Range(0, _profileCount).OrderBy(i => _profileIds[i] == "background" ? 0 : 1)
            .ThenBy(i => _profileIds[i], StringComparer.Ordinal).ToArray();
        _tieRanks = new int[_profileCount];
        for (int rank = 0; rank < ranked.Length; rank++) _tieRanks[ranked[rank]] = rank;
        _orders = model.Vocabulary.Select((vocabulary, n) =>
        {
            int capacity = 16;
            while (capacity < vocabulary.Features.Length * 2) capacity <<= 1;
            var keys = new ulong[capacity];
            Array.Fill(keys, Empty);
            var indices = new int[capacity];
            for (int index = 0; index < vocabulary.Features.Length; index++)
            {
                ulong key = Key(vocabulary.Features[index]);
                int slot = Slot(key, capacity - 1);
                while (keys[slot] != Empty)
                {
                    if (keys[slot] == key) throw new InvalidDataException("Duplicate vocabulary feature.");
                    slot = (slot + 1) & (capacity - 1);
                }
                keys[slot] = key;
                indices[slot] = index;
            }
            var weights = new long[vocabulary.Features.Length * _profileCount];
            for (int p = 0; p < _profileCount; p++)
            {
                var orderWeights = profiles[p].Orders[n].Weights;
                for (int index = 0; index < orderWeights.Length; index++) weights[index * _profileCount + p] = orderWeights[index];
            }
            return new Order(keys, indices, weights, profiles.Select(p => p.Orders[n].UnknownWeight).ToArray());
        }).ToArray();
    }

    /// <summary>Same contract as <see cref="LanguageScorer.Score"/>: an already normalized, capped slice.</summary>
    internal LanguageTextDecision Decide(ReadOnlySpan<int> scalars)
    {
        ArgumentOutOfRangeException.ThrowIfGreaterThan(scalars.Length, _model.Parameters.TextCapScalars);
        int profiles = _profileCount;
        Span<long> sums = stackalloc long[3 * profiles];
        Span<long> totals = stackalloc long[3];
        Span<long> known = stackalloc long[3];
        long letters = 0, words = 0;
        Order o1 = _orders[0], o2 = _orders[1], o3 = _orders[2];
        // Previous two symbols of the current padded word and how many it has.
        ulong p1 = 0, p2 = 0;
        int length = 0;

        void Add(Order order, int n, ulong key, Span<long> sums, Span<long> known)
        {
            int index = order.Find(key);
            if (index < 0) return;
            known[n]++;
            int row = index * profiles, baseIndex = n * profiles;
            for (int p = 0; p < profiles; p++) sums[baseIndex + p] = checked(sums[baseIndex + p] + order.Weights[row + p]);
        }
        void Emit(ulong u, Span<long> sums, Span<long> totals, Span<long> known)
        {
            totals[0]++;
            Add(o1, 0, u, sums, known);
            if (length >= 1)
            {
                totals[1]++;
                Add(o2, 1, p1 << 21 | u, sums, known);
            }
            if (length >= 2)
            {
                totals[2]++;
                Add(o3, 2, p2 << 42 | p1 << 21 | u, sums, known);
            }
            p2 = p1;
            p1 = u;
            length++;
        }

        foreach (int scalar in scalars)
        {
            switch (_tables.WordClass(scalar))
            {
                case UnicodeTables.LetterClass:
                    if (length == 0) Emit(Symbol(-1), sums, totals, known);
                    Emit((ulong)scalar + 2, sums, totals, known);
                    letters++;
                    break;
                case UnicodeTables.MarkClass:
                    if (length > 0) Emit((ulong)scalar + 2, sums, totals, known);
                    break;
                default:
                    if (length > 0)
                    {
                        Emit(Symbol(-2), sums, totals, known);
                        words++;
                        length = 0;
                    }
                    break;
            }
        }
        if (length > 0)
        {
            Emit(Symbol(-2), sums, totals, known);
            words++;
        }

        var combined = new long[profiles];
        for (int p = 0; p < profiles; p++)
        {
            long score = _priors[p];
            for (int n = 0; n < 3; n++)
            {
                long sum = checked(sums[n * profiles + p] + (totals[n] - known[n]) * _orders[n].UnknownWeights[p]);
                score = checked(score + _orderWeights[n] * (totals[n] == 0 ? 0 : LanguageScorer.FloorDiv(sum, totals[n])));
            }
            combined[p] = score;
        }
        bool Precedes(int a, int b) => combined[a] != combined[b] ? combined[a] > combined[b] : _tieRanks[a] < _tieRanks[b];
        int best = 0, second = -1;
        for (int p = 1; p < profiles; p++)
        {
            if (Precedes(p, best)) { second = best; best = p; }
            else if (second < 0 || Precedes(p, second)) second = p;
        }
        long margin = checked(combined[best] - combined[second]);
        long total = totals[0] + totals[1] + totals[2];
        long coverage = total == 0 ? 0 : checked(10000 * (known[0] + known[1] + known[2])) / total;
        var parameters = _model.Parameters;
        LanguageThreshold? bucket = null;
        foreach (var threshold in _model.Thresholds) if (threshold.Start <= letters) bucket = threshold;
        string reason = letters < parameters.MinLetters ? "minLetters"
            : words < parameters.MinWords ? "minWords"
            : bucket!.Enabled == 0 ? "bucketDisabled"
            : _profileIds[best] == "background" ? "background"
            : combined[best] < bucket.MinWinningScore ? "minWinningScore"
            : margin < bucket.MinMargin ? "minMargin"
            : coverage < bucket.MinKnownCoverageBp ? "minKnownCoverageBp"
            : "accepted";
        return new(reason == "accepted" ? _profileIds[best] : "und", reason, letters, words, _profileIds[best],
            _profileIds[second], margin, coverage, combined);
    }

    /// <summary><see cref="LanguageDocument.Detect"/> reduced to its aggregate: the same sampled windows, each decided
    /// in place on the normalized stream.</summary>
    internal LanguageAggregate DecideDocument(int[] stream)
    {
        var parameters = _model.Parameters;
        var ranges = LanguageDocument.Ranges(stream.Length, parameters.WindowCount, parameters.WindowScalars);
        var labels = new string[ranges.Length];
        var letters = new long[ranges.Length];
        for (int i = 0; i < ranges.Length; i++)
        {
            var decision = Decide(stream.AsSpan(ranges[i].Start, ranges[i].End - ranges[i].Start));
            labels[i] = decision.Label;
            letters[i] = decision.LetterCount;
        }
        return LanguageDocument.Aggregate(_model.Targets.ToArray(), labels, letters);
    }
}
