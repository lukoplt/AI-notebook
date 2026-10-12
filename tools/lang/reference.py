"""Independent, offline implementation of lang-detector-v1.

Unicode operations use only the committed 15.1 tables. Export logarithms are
proved with rational intervals; inference contains no floating point math.
"""

from bisect import bisect_right
from collections import Counter
from fractions import Fraction
from functools import lru_cache
import hashlib
import json
from pathlib import Path


class UnicodeData:
    def __init__(self, data: dict):
        if (data["format"], data["unicodeVersion"], data["normalizationTablesVersion"]) != (
                1, "15.1.0", "ucd-15.1.0-default-full-v1"):
            raise ValueError("incompatible Unicode tables")
        self.ranges = data["categories"]
        self.starts = [row[0] for row in self.ranges]
        self.ccc = dict(data["ccc"])
        self.decomposition = dict(data["decomposition"])
        self.composition = {(a, b): c for a, b, c in data["composition"]}
        self.case_fold = dict(data["caseFold"])
        self.lower = dict(data["simpleLower"])

    @classmethod
    def load(cls, path: Path):
        path = Path(path)
        raw = path.read_bytes()
        expected = path.with_name(path.name + ".sha256").read_text(encoding="ascii").strip()
        if hashlib.sha256(raw).hexdigest() != expected:
            raise ValueError("Unicode table SHA-256 mismatch")
        return cls(json.loads(raw))

    def category(self, cp: int) -> str:
        i = bisect_right(self.starts, cp) - 1
        return self.ranges[i][2] if i >= 0 and cp <= self.ranges[i][1] else "Cn"

    def simple_lower(self, cp: int) -> int:
        return self.lower.get(cp, cp)

    def fold(self, scalars: list[int]) -> list[int]:
        return [v for cp in scalars for v in self.case_fold.get(cp, (cp,))]

    @lru_cache(maxsize=32768)
    def _decompose(self, cp: int) -> tuple:
        if 0xAC00 <= cp < 0xAC00 + 11172:
            s = cp - 0xAC00
            result = (0x1100 + s // 588, 0x1161 + s % 588 // 28)
            return result + ((0x11A7 + s % 28,) if s % 28 else ())
        if cp in self.decomposition:
            return tuple(v for p in self.decomposition[cp] for v in self._decompose(p))
        return (cp,)

    def nfd(self, scalars: list[int]) -> list[int]:
        output = []
        # Stable counting buckets avoid quadratic reordering of long mark runs.
        pending = {}

        def flush():
            for ccc in sorted(pending):
                output.extend(pending[ccc])
            pending.clear()

        for scalar in scalars:
            for cp in self._decompose(scalar):
                ccc = self.ccc.get(cp, 0)
                if ccc == 0:
                    flush()
                    output.append(cp)
                else:
                    pending.setdefault(ccc, []).append(cp)
        flush()
        return output

    def _pair(self, a: int, b: int):
        if 0x1100 <= a < 0x1113 and 0x1161 <= b < 0x1176:
            return 0xAC00 + (a - 0x1100) * 588 + (b - 0x1161) * 28
        if 0xAC00 <= a < 0xAC00 + 11172 and (a - 0xAC00) % 28 == 0 and 0x11A8 <= b < 0x11C3:
            return a + b - 0x11A7
        return self.composition.get((a, b))

    def nfc(self, scalars: list[int]) -> list[int]:
        output, starter, last = [], None, 0
        for cp in self.nfd(scalars):
            current = self.ccc.get(cp, 0)
            replacement = (self._pair(output[starter], cp)
                           if starter is not None and (last == 0 or last < current) else None)
            if replacement is not None:
                output[starter] = replacement
            else:
                if current == 0:
                    starter = len(output)
                output.append(cp)
                last = current
        return output


def decode_utf16(units: list[int], cap: int) -> list[int]:
    if cap < 0:
        raise ValueError("negative cap")
    output, i = [], 0
    while i < len(units) and len(output) < cap:
        a = units[i]
        if type(a) is not int or not 0 <= a <= 65535:
            raise ValueError("invalid UTF-16 unit")
        if 0xD800 <= a <= 0xDBFF and i + 1 < len(units) and 0xDC00 <= units[i + 1] <= 0xDFFF:
            output.append(65536 + (a - 55296) * 1024 + units[i + 1] - 56320)
            i += 2
        else:
            output.append(65533 if 0xD800 <= a <= 0xDFFF else a)
            i += 1
    return output


def _normalize_scalars(scalars, tables, cap):
    return tables.nfc(tables.fold(tables.nfc(scalars)))[:cap]


def normalize_utf16(units, tables, input_cap):
    return _normalize_scalars(decode_utf16(units, input_cap), tables, input_cap)


def normalize(text: str, tables: UnicodeData, input_cap: int) -> list[int]:
    if input_cap < 0:
        raise ValueError("negative cap")
    scalars = [ord(c) for c in text[:input_cap]]
    if any(0xD800 <= cp <= 0xDFFF for cp in scalars):
        raise ValueError("string input must contain Unicode scalars, not surrogates")
    return _normalize_scalars(scalars, tables, input_cap)


def classify(scalars: list[int], tables: UnicodeData) -> dict:
    words, active, letters = [], [], 0
    for cp in scalars:
        category = tables.category(cp)
        if category.startswith("L"):
            active.append(cp)
            letters += 1
        elif category.startswith("M"):
            if active:
                active.append(cp)
        elif active:
            words.append(active)
            active = []
    if active:
        words.append(active)
    return {"words": ["".join(map(chr, w)) for w in words], "wordScalars": words,
            "boundaryWords": [[-1] + w + [-2] for w in words],
            "letterCount": letters, "wordCount": len(words)}


def features(words: list[list[int]]) -> list[Counter]:
    counts = [Counter(), Counter(), Counter()]
    for word in words:
        padded = [-1] + word + [-2]
        for n in (1, 2, 3):
            counts[n - 1].update(tuple(padded[i:i + n]) for i in range(len(padded) - n + 1))
    return counts


def round_even(q: Fraction) -> int:
    low, remainder = divmod(q.numerator, q.denominator)
    twice = 2 * remainder
    return low + int(twice > q.denominator or (twice == q.denominator and low % 2 != 0))


@lru_cache(maxsize=131072)
def log_interval(x: Fraction, terms: int) -> tuple:
    if not 1 <= x <= 2 or terms <= 0:
        raise ValueError("log interval requires 1 <= x <= 2 and positive terms")
    z = (x - 1) / (x + 1)
    power, total = z, Fraction(0)
    for j in range(terms):
        total += power / (2 * j + 1)
        power *= z * z
    lower = 2 * total
    return lower, lower + 2 * power / ((2 * terms + 1) * (1 - z * z))


@lru_cache(maxsize=None)
def round_log_weight(numerator: int, denominator: int, scale: int = 1024) -> int:
    if (type(numerator) is not int or type(denominator) is not int or type(scale) is not int
            or numerator <= 0 or denominator <= 0 or numerator > denominator or scale <= 0):
        raise ValueError("expected 0 < probability <= 1 and positive integer scale")
    if numerator == denominator:
        return 0
    x, shifts = Fraction(numerator, denominator), 0
    while x < 1:
        x *= 2
        shifts += 1
    terms = 8
    while True:
        lo, hi = log_interval(x, terms)
        lo2, hi2 = log_interval(Fraction(2), terms)
        a, b = round_even(scale * (lo - shifts * hi2)), round_even(scale * (hi - shifts * lo2))
        if a == b:
            return a
        terms *= 2


def export_profiles(training: dict, caps: list[int], tables: UnicodeData) -> dict:
    """Accept fixture word/count rows or prepared normalizedScalars rows.

    Iterable profile rows are consumed once, with each example independently
    text-capped; no validation or test partition is consulted here.
    """
    ids = ["background"] + sorted(p for p in training if p != "background")
    if "background" not in training or len(caps) != 3 or any(c <= 0 for c in caps):
        raise ValueError("background and three positive feature caps required")
    counts = {}
    for profile in ids:
        orders = [Counter(), Counter(), Counter()]
        for row in training[profile]:
            scalars = (row["normalizedScalars"] if "normalizedScalars" in row
                       else normalize(row["word"], tables, 5000000))
            repetitions = row.get("count", 1)
            if type(repetitions) is not int or repetitions <= 0:
                raise ValueError("training occurrence count must be positive")
            for n, counter in enumerate(features(classify(scalars[:8192], tables)["wordScalars"])):
                for feature, count in counter.items():
                    orders[n][feature] += count * repetitions
        counts[profile] = orders
    vocabulary = []
    for n, cap in enumerate(caps):
        union = set()
        for profile in ids:
            union.update(sorted(counts[profile][n], key=lambda f: (-counts[profile][n][f], f))[:cap])
        vocabulary.append(sorted(union))
    profiles = []
    for profile in ids:
        orders = []
        for n, vocab in enumerate(vocabulary):
            counter = counts[profile][n]
            total = sum(counter.values())
            denominator = total + len(vocab) + 1
            unknown = total - sum(counter[f] for f in vocab)
            orders.append({"order": n + 1,
                           "weights": [round_log_weight(counter[f] + 1, denominator) for f in vocab],
                           "unknownWeight": round_log_weight(unknown + 1, denominator)})
        profiles.append({"id": profile, "priorWeight": round_log_weight(1, len(ids)), "orders": orders})
    return {"vocabulary": [{"order": n + 1, "features": [list(f) for f in vocab]}
                           for n, vocab in enumerate(vocabulary)], "profiles": profiles}


class Scorer:
    """Reusable vocabulary maps for offline bulk evaluation of a frozen model."""

    def __init__(self, model: dict, tables: UnicodeData):
        self.model, self.tables = model, tables
        self.vocabulary = [{tuple(f): i for i, f in enumerate(v["features"])} for v in model["vocabulary"]]

    def score(self, scalars: list[int]) -> dict:
        model, parameters = self.model, self.model["parameters"]
        result = classify(scalars, self.tables)
        del result["boundaryWords"]
        counts = features(result["wordScalars"])
        totals = [sum(c.values()) for c in counts]
        known = [sum(count for f, count in c.items() if f in self.vocabulary[n]) for n, c in enumerate(counts)]
        profiles = {}
        for profile in model["profiles"]:
            sums = []
            for n, order in enumerate(profile["orders"]):
                vocab = self.vocabulary[n]
                sums.append(sum(count * (order["weights"][vocab[f]] if f in vocab else order["unknownWeight"])
                                for f, count in counts[n].items()))
            scores = [s // f if f else 0 for s, f in zip(sums, totals)]
            profiles[profile["id"]] = {"weightedSums": sums, "orderScores": scores,
                "combinedScore": profile["priorWeight"] + sum(w * s for w, s in zip(parameters["orderWeights"], scores))}
        ranking = sorted(profiles, key=lambda p: (-profiles[p]["combinedScore"], p != "background", p))
        winner, runner = ranking[:2]
        winning_score = profiles[winner]["combinedScore"]
        margin = winning_score - profiles[runner]["combinedScore"]
        coverage = 10000 * sum(known) // sum(totals) if sum(totals) else 0
        threshold = next((t for t in reversed(model["thresholds"]) if result["letterCount"] >= t["start"]), None)
        if result["letterCount"] < parameters["minLetters"]:
            reason = "minLetters"
        elif result["wordCount"] < parameters["minWords"]:
            reason = "minWords"
        elif not threshold["enabled"]:
            reason = "bucketDisabled"
        elif winner == "background":
            reason = "background"
        elif winning_score < threshold["minWinningScore"]:
            reason = "minWinningScore"
        elif margin < threshold["minMargin"]:
            reason = "minMargin"
        elif coverage < threshold["minKnownCoverageBp"]:
            reason = "minKnownCoverageBp"
        else:
            reason = "accepted"
        result.update(bucketStart=threshold["start"] if threshold else None,
            features=[[{"symbols": list(f), "count": c[f]} for f in sorted(c)] for c in counts],
            featureCounts=totals, knownCounts=known, unknownCounts=[f - k for f, k in zip(totals, known)],
            profiles=profiles, winner=winner, runnerUp=runner, margin=margin, coverageBp=coverage,
            label=winner if reason == "accepted" else "und", reason=reason)
        return result


def score_slice(scalars: list[int], model: dict, tables: UnicodeData) -> dict:
    return Scorer(model, tables).score(scalars)


def detect_text(text: str, model: dict, tables: UnicodeData) -> dict:
    p = model["parameters"]
    return score_slice(normalize(text, tables, p["inputCapScalars"])[:p["textCapScalars"]], model, tables)


def window_ranges(length: int, count: int, size: int) -> list:
    if length < 0 or count <= 0 or size <= 0:
        raise ValueError("invalid window parameters")
    if not length:
        return []
    k = min(count, (length + size - 1) // size)
    w = min(size, length // k)
    starts = [0 if k == 1 else i * (length - w) // (k - 1) for i in range(k)]
    return [[s, s + w] for s in starts]


def aggregate(targets, labels, letters, dominance_bp=7000):
    if len(labels) != len(letters) or any(n < 0 for n in letters):
        raise ValueError("invalid aggregation rows")
    accepted = dict.fromkeys(targets, 0)
    total, unknown = sum(letters), 0
    for label, count in zip(labels, letters):
        if label in accepted:
            accepted[label] += count
        else:
            unknown += count
    dominant = next((p for p in targets if accepted[p] > 0 and 10000 * accepted[p] >= dominance_bp * total), None)
    mixed = sum(n > 0 for n in accepted.values()) >= 2
    return {"sampledLetters": total, "acceptedLetters": accepted, "unknownLetters": unknown,
            "sharesBp": {p: 10000 * n // total if total else 0 for p, n in accepted.items()},
            "unknownShareBp": 10000 * unknown // total if total else 0,
            "langCoverageBp": 10000 * sum(accepted.values()) // total if total else 0,
            "label": dominant or ("mixed" if mixed else "und"),
            "reason": "dominant" if dominant else ("mixed" if mixed else "insufficientEvidence")}


def detect_document(text: str, model: dict, tables: UnicodeData) -> dict:
    p = model["parameters"]
    scalars = normalize(text, tables, p["inputCapScalars"])
    scorer = Scorer(model, tables)
    ranges = window_ranges(len(scalars), p["windowCount"], p["windowScalars"])
    windows = [{"start": a, "end": b, "expected": scorer.score(scalars[a:b])} for a, b in ranges]
    return {"normalizedScalarCount": len(scalars), "windowCount": len(windows),
            "windowScalars": ranges[0][1] if ranges else 0, "windows": windows,
            **aggregate(model["targets"], [w["expected"]["label"] for w in windows],
                        [w["expected"]["letterCount"] for w in windows], p["mixedDominanceBp"])}
