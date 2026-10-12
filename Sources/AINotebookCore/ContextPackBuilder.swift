import Foundation

/// Packs an already scoped, hydrated snapshot without consulting mutable application state.
public enum ContextPackBuilder {
    private typealias Rendering = ContextPackRendering

    /// A nil estimator resolves to the bundled v2 estimator for the request's model; without
    /// a proven digest that is v2's explicitly uncalibrated UTF-8 fallback.
    public static func build(_ input: ContextPackInput,
                             estimator suppliedEstimator: (any ContextTokenEstimating)? = nil,
                             tuning suppliedTuning: RagRuntimeTuning? = nil) throws -> PreparedContextRequest {
        let estimator: any ContextTokenEstimating = try suppliedEstimator ?? TokenEstimatorV2.bundled(model: input.model.model)
        // Only the evidence share is tuned here; input.fetchK/topK stay explicit caller values.
        let tuning = try suppliedTuning ?? RagRuntimeTuning.bundled()
        try validate(input, estimator: estimator)
        var input = input
        let empty = input.scope.kind == "selection" && input.scope.sourceIds.isEmpty && input.scope.folderIds.isEmpty
        let originalPassages = input.mode == "overview" ? input.overviewCandidates : input.candidates
        let originalFiles = Set((originalPassages.map(\.sourceId) + input.folderMap.map(\.sourceId)))
        if empty {
            input.candidates = []; input.neighbours = []; input.overviewCandidates = []; input.folderMap = []
        }
        let system = try Rendering.system(input, estimator: estimator)
        let reservedScope = try Rendering.section("scope", body: Rendering.scopeBody(input,
            passages: RagContractV1.Pack.maxPassages, files: input.coverage.filesInScope), estimator: estimator)
        let question = try Rendering.section("question", body: input.question, label: "QUESTION", estimator: estimator)
        let mandatory = try sum([8, reservedScope.tokens, question.tokens] + system.map(\.tokens))
        let available = input.model.runtimeContext - input.model.maxOutputTokens
        guard available > 0, mandatory <= available else { throw ContextPackError.contextTooSmall }
        let remaining = available - mandatory

        var unique: [Int64: PackPassage] = [:], duplicateIds = Set<Int64>()
        for p in input.mode == "overview" ? input.overviewCandidates : input.candidates {
            if unique.updateValue(p, forKey: p.chunkId) != nil { duplicateIds.insert(p.chunkId) }
        }
        let singleSource = input.scope.kind == "selection" && Set(input.scope.sourceIds).count == 1 && input.scope.folderIds.isEmpty
        let direct = input.mode == "overview" ? ContextPackAlgorithms.overviewOrder(Array(unique.values))
            : ContextPackAlgorithms.diversity(Array(unique.values), singleSource: singleSource)
        // retrieval-paths v2 (§6): an inventory question reserves a larger map share for its matches.
        let inventory = input.pathInventory == true
            && input.folderMap.contains { $0.pathRank != nil && $0.publishedRevisionId != nil }
        let matchingBudget = inventory ? Rendering.MatchingBudget(
            ceiling: ContextPackAlgorithms.share(remaining, Rendering.Inventory.mapShareBp),
            floorLimit: ContextPackAlgorithms.share(remaining, Rendering.Inventory.floorMaxShareBp)) : nil
        let map = try Rendering.map(input, ceiling: ContextPackAlgorithms.share(remaining, RagContractV1.Pack.mapMaxShareBp),
                                    direct: direct, estimator: estimator, matchingBudget: matchingBudget)
        let mapCost = map.section?.tokens ?? 0
        let externalCeiling = ContextPackAlgorithms.share(remaining, RagContractV1.Pack.noteWebMaxShareBp)
        let externalOrder = input.external.filter { $0.kind == "note" } + input.external.filter { $0.kind == "web" }
        var external: [PackSection] = [], externalIds = Set<Data>(), externalCost = 0
        for item in externalOrder {
            let section = try Rendering.section(item.kind, body: item.text, language: item.language,
                label: "\(item.kind.uppercased()) — NOT CONTENT OF THE SELECTED FOLDER", estimator: estimator)
            if section.tokens <= externalCeiling - externalCost {
                external.append(section); externalCost += section.tokens; externalIds.insert(Data(item.id.utf8))
            }
        }
        let history = Array(input.history.reversed())
        let historyCosts = try history.map { turn in
            try sum([8, Rendering.section("history", body: turn.user, estimator: estimator).tokens,
                     Rendering.section("history", body: turn.assistant, estimator: estimator).tokens])
        }
        let passages = try direct.map { passage in
            let prefixes = input.mode == "answer" ? try Rendering.prefixes(passage, estimator: estimator) : []
            return PackBudgetPassage(id: passage.chunkId,
                tokens: try Rendering.evidenceTokens(PackEvidenceBlock(passage: passage), estimator: estimator),
                truncationCandidates: prefixes.map { PackBudgetPrefix(endScalar: $0.end - (passage.start ?? 0), tokens: $0.tokens) })
        }
        let budget = try ContextPackAlgorithms.budget(PackBudgetInput(runtimeContext: input.model.runtimeContext,
            maxOutputTokens: input.model.maxOutputTokens, mandatoryTokens: mandatory, evidenceBudgetCap: input.evidenceBudgetCap,
            topK: input.topK, passages: passages, mapTokensDesired: mapCost, noteWebTokensDesired: externalCost,
            historyTurnTokensNewestFirst: historyCosts, mapCeilingTokens: inventory ? mapCost : nil,
            evidenceCeilingTokens: inventory ? remaining - mapCost - externalCost : nil), evidenceShareBp: tuning.evidenceShareBp)
        var selectedIds = Set(budget.includedPassageIds)
        var historyCount = budget.historyTurnsIncluded, historyCost = budget.historyTokens
        let ceiling = min(input.evidenceBudgetCap ?? remaining, remaining - mapCost - externalCost - historyCost)
        var blocks: [PackEvidenceBlock] = [], clipped: String?
        for (rank, passage) in direct.enumerated() where selectedIds.contains(passage.chunkId) {
            var block = PackEvidenceBlock(passage: passage, rank: rank)
            if passage.chunkId == budget.truncatedPassageId {
                let end = (passage.start ?? 0) + budget.truncatedPassageEndScalar!
                block = Rendering.clip(passage, end: end)
                block.rank = rank
                clipped = "\(passage.chunkId):\(end)"
            }
            blocks.append(block)
        }
        blocks = try Rendering.mergeBlocks(blocks, ceiling: ceiling, estimator: estimator)
        func evidenceCost(_ values: [PackEvidenceBlock]) throws -> Int {
            try sum(values.map { try Rendering.evidenceTokens($0, estimator: estimator) })
        }
        func tryAdd(_ passage: PackPassage, rank: Int) throws -> Bool {
            let trial = try Rendering.mergeBlocks(blocks + [PackEvidenceBlock(passage: passage, rank: rank)],
                                                  ceiling: ceiling, estimator: estimator)
            if trial.count <= RagContractV1.Pack.maxPassages, try evidenceCost(trial) <= ceiling {
                blocks = trial
                return true
            }
            return false
        }
        let directLimit = min(input.topK, RagContractV1.Pack.maxPassages)
        if budget.evidenceTarget > 0 {
            for (rank, passage) in direct.enumerated() {
                if selectedIds.count >= directLimit { break }
                if !selectedIds.contains(passage.chunkId), try tryAdd(passage, rank: rank) { selectedIds.insert(passage.chunkId) }
            }
        }
        var neighbourIds = Set<Int64>(), seenNeighbours = Set<Int64>(), neighbourReasons: [Int64: String] = [:]
        if input.mode == "answer" {
            for (rank, passage) in direct.enumerated() where selectedIds.contains(passage.chunkId) {
                for delta in [-1, 1] {
                    for neighbour in input.neighbours.sorted(by: { $0.chunkId < $1.chunkId }) {
                        guard neighbour.sourceId == passage.sourceId, neighbour.ordinal == passage.ordinal + delta,
                              !selectedIds.contains(neighbour.chunkId), !seenNeighbours.contains(neighbour.chunkId) else { continue }
                        var reason = "neighbourBudget"
                        if neighbour.revisionId != passage.revisionId || input.sourceRevisions[String(passage.sourceId)] != passage.revisionId {
                            // A manifest hit may precede a hit at the published revision.
                            // Only an eligible pairing consumes this neighbour's attempt.
                            neighbourReasons[neighbour.chunkId] = "revisionMismatch"
                            continue
                        }
                        seenNeighbours.insert(neighbour.chunkId)
                        if passage.chunkId == budget.truncatedPassageId,
                                  neighbour.end == nil || passage.start == nil || neighbour.end! > blocks.first(where: {
                                      $0.members.contains(where: { $0.chunkId == passage.chunkId })
                                  })!.passage.end! {
                            reason = "truncated"
                        } else if budget.evidenceTarget > 0, try tryAdd(neighbour, rank: rank) {
                            neighbourIds.insert(neighbour.chunkId)
                            continue
                        }
                        neighbourReasons[neighbour.chunkId] = reason
                    }
                }
            }
        }
        let used = try evidenceCost(blocks)
        while historyCount < history.count && historyCosts[historyCount] <= remaining - used - mapCost - externalCost - historyCost {
            historyCost += historyCosts[historyCount]; historyCount += 1
        }
        var firstSource: [Int64: Int] = [:]
        for (rank, passage) in direct.enumerated() where selectedIds.contains(passage.chunkId) {
            if firstSource[passage.sourceId] == nil { firstSource[passage.sourceId] = rank }
        }
        blocks.sort {
            (firstSource[$0.passage.sourceId]!, $0.rank, $0.passage.start ?? -1, $0.passage.chunkId)
                < (firstSource[$1.passage.sourceId]!, $1.rank, $1.passage.start ?? -1, $1.passage.chunkId)
        }
        let citations = blocks.enumerated().map { Rendering.citation($0.element, marker: $0.offset + 1) }
        let includedFiles = Set(blocks.map { $0.passage.sourceId })
        var sections = [try Rendering.section("scope", body: Rendering.scopeBody(input, passages: blocks.count,
            files: includedFiles.count), label: "SCOPE", tokens: reservedScope.tokens, estimator: estimator)]
        if let section = map.section { sections.append(section) }
        sections += try blocks.enumerated().map { try Rendering.evidenceSection($0.element, marker: $0.offset + 1, estimator: estimator) }
        sections += external + [question]
        var messages = [PackMessage(role: "system", sections: system)]
        for turn in history.prefix(historyCount).reversed() {
            messages.append(PackMessage(role: "user", sections: [try Rendering.section("history", body: turn.user, estimator: estimator)]))
            messages.append(PackMessage(role: "assistant", sections: [try Rendering.section("history", body: turn.assistant, estimator: estimator)]))
        }
        messages.append(PackMessage(role: "user", sections: sections))
        var included: [PackItem] = [], omitted: [PackOmission] = []
        func ledger(_ kind: String, _ id: String, yes: Bool, reason: String) {
            if yes { included.append(PackItem(kind: kind, id: id)) }
            else { omitted.append(PackOmission(kind: kind, id: id, reason: reason)) }
        }
        for passage in empty ? originalPassages.sorted(by: { $0.chunkId < $1.chunkId }) : direct {
            ledger("passage", String(passage.chunkId), yes: selectedIds.contains(passage.chunkId),
                   reason: empty ? "emptySelection" : selectedIds.count >= directLimit ? "topK" : "evidenceBudget")
        }
        for id in duplicateIds.sorted() { ledger("passage", String(id), yes: false, reason: "duplicate") }
        if let clipped { ledger("passage", clipped, yes: false, reason: "truncated") }
        var fileOrder: [Int64] = [], seenFiles = Set<Int64>()
        for passage in direct where seenFiles.insert(passage.sourceId).inserted { fileOrder.append(passage.sourceId) }
        fileOrder += originalFiles.subtracting(seenFiles).sorted()
        for id in fileOrder { ledger("file", String(id), yes: includedFiles.contains(id), reason: empty ? "emptySelection" : "evidenceBudget") }
        let retainedHistory = Set(history.prefix(historyCount).map(\.id))
        for turn in input.history { ledger("history", String(turn.id), yes: retainedHistory.contains(turn.id), reason: "historyBudget") }
        let neighbours = Dictionary(input.neighbours.map { ($0.chunkId, $0) }, uniquingKeysWith: { a, _ in a }).values.sorted {
            ($0.sourceId, $0.ordinal, $0.chunkId) < ($1.sourceId, $1.ordinal, $1.chunkId)
        }
        for neighbour in neighbours where !selectedIds.contains(neighbour.chunkId) {
            ledger("neighbour", String(neighbour.chunkId), yes: neighbourIds.contains(neighbour.chunkId),
                   reason: neighbourReasons[neighbour.chunkId] ?? "neighbourBudget")
        }
        for item in externalOrder { ledger("external", item.id, yes: externalIds.contains(Data(item.id.utf8)), reason: "externalBudget") }
        for id in map.included { ledger("map", id, yes: true, reason: "mapBudget") }
        for id in map.omitted { ledger("map", id, yes: false, reason: "mapBudget") }
        var pairs = empty ? Set<PackSourceRevision>() : Set(input.sourceRevisions.map { PackSourceRevision(sourceId: Int64($0.key)!, revisionId: $0.value) })
        pairs.formUnion(citations.map { PackSourceRevision(sourceId: $0.sourceId, revisionId: $0.revisionId!) })
        guard try sum(messages.flatMap { [4] + $0.sections.map(\.tokens) }) <= available else { throw ContextPackError.invalidInput }
        return PreparedContextRequest(estimatorVersion: estimator.version,
            model: PreparedPackModel(providerId: input.model.providerId, model: input.model.model,
                runtimeContext: input.model.runtimeContext, maxOutputTokens: input.model.maxOutputTokens,
                contextWindowKnown: input.model.contextWindowKnown), messages: messages,
            options: PackOptions(numCtx: input.model.providerType == "ollama" ? input.model.runtimeContext : nil,
                                 maxTokens: input.model.maxOutputTokens), citationMap: citations,
            included: included, omitted: omitted, coverage: PackCoverage(corpus: input.coverage,
                turn: PackTurnCoverage(passages: blocks.count, filesIncluded: includedFiles.count,
                    candidatesWithPublishedChunks: input.overviewCandidates.count, overview: input.mode == "overview")),
            generationId: input.generationId, sourceRevisions: pairs.sorted { ($0.sourceId, $0.revisionId) < ($1.sourceId, $1.revisionId) })
    }

    /// Bounds are checked before any packing arithmetic, even for items subsequently excluded.
    private static func validate(_ input: ContextPackInput, estimator: any ContextTokenEstimating) throws {
        func integer(_ n: Int64, max: Int64 = ContextPackAlgorithms.maxJSONInteger, min: Int64 = 0) throws {
            guard n >= min && n <= max else { throw ContextPackError.invalidInput }
        }
        func count(_ n: Int, positive: Bool = false) throws { try integer(Int64(n), max: Int64(Int32.max), min: positive ? 1 : 0) }
        for n in [input.model.runtimeContext, input.model.maxOutputTokens, input.fetchK, input.topK, estimator.version] { try count(n, positive: true) }
        guard input.fetchK >= input.topK, ["answer", "overview"].contains(input.mode),
              ["ollama", "anthropic", "openai", "openai_compatible", "openwebui"].contains(input.model.providerType),
              ["all", "selection"].contains(input.scope.kind) else { throw ContextPackError.invalidInput }
        let languages = Set(["en", "cs", "sk", "de", "und", "mixed"])
        guard input.scope.languages.allSatisfy(languages.contains) else { throw ContextPackError.invalidInput }
        if let cap = input.evidenceBudgetCap { try count(cap) }
        if let id = input.generationId { try integer(id) }
        for id in input.scope.sourceIds + input.scope.folderIds { try integer(id) }
        let c = input.coverage
        for n in [c.filesInScope, c.searchable, c.pending, c.error, c.skipped, c.missing, c.unavailable, c.refreshPending, c.refreshError] { try count(n) }
        guard c.searchable + c.pending + c.error == c.filesInScope,
              c.refreshPending + c.refreshError <= c.filesInScope else { throw ContextPackError.invalidInput }
        for (key, revision) in input.sourceRevisions {
            guard let id = Int64(key), key == String(id) else { throw ContextPackError.invalidInput }
            try integer(id); try integer(revision)
        }
        var historyIds = Set<Int64>()
        for turn in input.history {
            try integer(turn.id)
            guard historyIds.insert(turn.id).inserted else { throw ContextPackError.invalidInput }
        }
        var externalIds = Set<Data>()
        guard input.external.filter({ $0.kind == "note" }).count <= 1 else { throw ContextPackError.invalidInput }
        for item in input.external {
            guard ["note", "web"].contains(item.kind), languages.contains(item.language),
                  externalIds.insert(Data(item.id.utf8)).inserted else { throw ContextPackError.invalidInput }
        }
        let all = input.candidates + input.neighbours + input.overviewCandidates
        let empty = input.scope.kind == "selection" && input.scope.sourceIds.isEmpty && input.scope.folderIds.isEmpty
        guard empty || Set(all.map(\.sourceId) + input.folderMap.map(\.sourceId)).count <= c.filesInScope else { throw ContextPackError.invalidInput }
        func identity(source: Int64, folder: Int64?, path: String, name: String) throws {
            try integer(source)
            if let folder { try integer(folder) }
            let parts = path.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, !path.unicodeScalars.contains(where: {
                $0 == "\\" || $0 == ":" || $0.value < 32 || (127...159).contains($0.value)
            }), parts.allSatisfy({ !$0.isEmpty && String($0) != "." && String($0) != ".." }),
                !name.isEmpty, !name.unicodeScalars.contains(where: {
                    $0 == "/" || $0 == "\\" || $0 == ":" || (127...159).contains($0.value)
                        || ($0.value < 32 && ![9, 10, 13].contains($0.value))
                }) else { throw ContextPackError.invalidInput }
        }
        var files = Set<Int64>()
        for file in input.folderMap {
            try identity(source: file.sourceId, folder: file.folderId, path: file.relPath, name: file.displayName)
            guard files.insert(file.sourceId).inserted else { throw ContextPackError.invalidInput }
            if let revision = file.publishedRevisionId {
                try integer(revision)
                guard input.sourceRevisions[String(file.sourceId)] == revision else { throw ContextPackError.invalidInput }
            }
        }
        var identities: [Int64: PackPassage] = [:]
        var groups: [PackSourceRevision: [PackPassage]] = [:]
        for p in all {
            try identity(source: p.sourceId, folder: p.folderId, path: p.relPath, name: p.displayName)
            try integer(p.chunkId); try integer(p.revisionId); try count(p.ordinal); try integer(p.rrfMicro, max: 2_000_000)
            guard languages.contains(p.language), (p.start == nil) == (p.end == nil) else { throw ContextPackError.invalidInput }
            if let start = p.start, let end = p.end {
                try integer(Int64(start)); try integer(Int64(end))
                guard start < end, end - start == p.text.unicodeScalars.count else { throw ContextPackError.invalidInput }
                groups[PackSourceRevision(sourceId: p.sourceId, revisionId: p.revisionId), default: []].append(p)
            }
            for page in [p.pageFrom, p.pageTo].compactMap({ $0 }) { try count(page) }
            if let from = p.pageFrom, let to = p.pageTo, from > to { throw ContextPackError.invalidInput }
            for prefix in p.truncationCandidates { try integer(Int64(prefix.end)); try count(prefix.tokens, positive: true) }
            _ = try Rendering.prefixes(p, estimator: estimator)
            if let previous = identities[p.chunkId] {
                guard previous == p, zip([previous.relPath, previous.displayName, previous.text], [p.relPath, p.displayName, p.text])
                    .allSatisfy({ $0.utf8.elementsEqual($1.utf8) }) else { throw ContextPackError.invalidInput }
            }
            identities[p.chunkId] = p
        }
        for group in groups.values {
            for (index, a) in group.enumerated() {
                for b in group.dropFirst(index + 1) {
                    let lo = max(a.start!, b.start!), hi = min(a.end!, b.end!)
                    if lo < hi {
                        let left = a.text.unicodeScalars.dropFirst(lo - a.start!).prefix(hi - lo)
                        let right = b.text.unicodeScalars.dropFirst(lo - b.start!).prefix(hi - lo)
                        guard left.elementsEqual(right) else { throw ContextPackError.invalidInput }
                    }
                }
            }
        }
        var overviewSources = Set<Int64>()
        for p in input.overviewCandidates {
            guard overviewSources.insert(p.sourceId).inserted, p.ordinal == 0,
                  input.sourceRevisions[String(p.sourceId)] == p.revisionId else { throw ContextPackError.invalidInput }
        }
    }

    private static func sum(_ costs: [Int]) throws -> Int {
        var result: Int64 = 0
        for cost in costs {
            guard cost >= 0 && cost <= Int32.max else { throw ContextPackError.invalidInput }
            let next = result.addingReportingOverflow(Int64(cost))
            guard !next.overflow else { throw ContextPackError.invalidInput }
            result = next.partialValue
        }
        return Int(result)
    }
}
