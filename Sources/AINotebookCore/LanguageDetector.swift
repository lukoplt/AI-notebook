import Foundation

/// An immutable offline detector. Missing or invalid resources preserve the
/// distinction between unavailable detection (`nil`) and inconclusive (`und`).
public struct LanguageDetector: Sendable {
    private let scorer: LanguageScorer?

    private init(scorer: LanguageScorer?) { self.scorer = scorer }
    public static var unavailable: LanguageDetector { LanguageDetector(scorer: nil) }
    public var isAvailable: Bool { scorer != nil }
    public static func bundled() -> LanguageDetector { cached }
    private static let cached = load(readResource: bundledResourceData)

    public func detectText(_ text: String) -> LanguageTextResult? {
        guard let scorer else { return nil }
        let stream = LanguageNormalization.stream(text, tables: scorer.tables,
                                                   cap: scorer.model.parameters.inputCapScalars)
        return scorer.score(Array(stream.prefix(scorer.model.parameters.textCapScalars)))
    }
    public func detectText(utf16Units: [UInt16]) -> LanguageTextResult? {
        guard let scorer else { return nil }
        let stream = LanguageNormalization.stream(utf16Units: utf16Units, tables: scorer.tables,
                                                   cap: scorer.model.parameters.inputCapScalars)
        return scorer.score(Array(stream.prefix(scorer.model.parameters.textCapScalars)))
    }

    /// Run once on a revision's canonical text before scoring its chunks.
    /// Persist the label/shares/coverage for scope headers; window offsets are
    /// normalized-stream diagnostics and must not be used as citation spans.
    public func detectDocument(_ text: String) -> LanguageDocumentResult? {
        guard let scorer else { return nil }
        return LanguageDocument.detect(stream: LanguageNormalization.stream(text, tables: scorer.tables,
            cap: scorer.model.parameters.inputCapScalars), scorer: scorer)
    }
    public func detectDocument(utf16Units: [UInt16]) -> LanguageDocumentResult? {
        guard let scorer else { return nil }
        return LanguageDocument.detect(stream: LanguageNormalization.stream(utf16Units: utf16Units,
            tables: scorer.tables, cap: scorer.model.parameters.inputCapScalars), scorer: scorer)
    }

    /// Ingestion's per-chunk detection: exactly the label and reason of `detectText`
    /// (contract `lang-detector-v1`), without its diagnostics.
    func decideText(_ text: String) -> LanguageTextDecision? {
        guard let scorer else { return nil }
        let stream = LanguageNormalization.stream(text, tables: scorer.tables,
                                                   cap: scorer.model.parameters.inputCapScalars)
        return stream.withUnsafeBufferPointer {
            scorer.fast.decide(UnsafeBufferPointer(rebasing: $0.prefix(scorer.model.parameters.textCapScalars)))
        }
    }

    /// Ingestion's document detection: exactly the aggregate (label, reason, shares,
    /// coverage) of `detectDocument`, without per-window diagnostics.
    func decideDocument(_ text: String) -> LanguageAggregate? {
        guard let scorer else { return nil }
        return scorer.fast.decideDocument(stream: LanguageNormalization.stream(text, tables: scorer.tables,
            cap: scorer.model.parameters.inputCapScalars))
    }

    // These seams are internal so callers cannot deploy an unverified model.
    init(testModelData: Data, tables: UnicodeTables) throws {
        let model = try LanguageModel.parse(testModelData, tables: tables, allowSynthetic: true)
        try require(model.kind == "synthetic", "test initializer requires a synthetic model")
        scorer = LanguageScorer(model: model, tables: tables)
    }

    static func load(readResource: (String) throws -> Data) -> LanguageDetector {
        do {
            // Read each fixed resource once, then validate this immutable snapshot.
            var resources: [String: Data] = [:]
            for name in LanguageBundle.names { resources[name] = try readResource(name) }
            let tables = try LanguageBundle.unicode(resources)
            let artifact = try LanguageBundle.data("lang-detector-v1.json", resources)
            let model = try LanguageModel.parse(artifact, tables: tables, allowSynthetic: false)
            let manifest = try LanguageJSON.parse(LanguageBundle.data("lang-detector-v1.manifest.json", resources))
            try LanguageManifest.validate(manifest, model: model, artifact: artifact, resources: resources)
            return LanguageDetector(scorer: LanguageScorer(model: model, tables: tables))
        } catch { return .unavailable }
    }

    static func bundledResourceData(_ name: String) throws -> Data {
        guard LanguageBundle.names.contains(name) else { throw UnicodeTables.LoadError.missingResource(name) }
        return try UnicodeTables.resourceData(name)
    }
}

private enum LanguageBundle {
    typealias JSON = LanguageJSON.Value
    static let names = ["lang-detector-v1.json", "lang-detector-v1.manifest.json", "unicode-15.1.0.json",
        "unicode-15.1.0.json.sha256", "unicode-sources-v1.json", "UNICODE-LICENSE.txt", "NOTICE", "ATTRIBUTION.md"]
    static let artifactPath = "Sources/AINotebookCore/Resources/Language/lang-detector-v1.json"
    static let tableHash = "407889e2ac750a0daca62b65c9a3b4e282d85c1aae978b5cc30d88e67acd7eb9"
    static let licenseHash = "e7a93b009565cfce55919a381437ac4db883e9da2126fa28b91d12732bc53d96"
    static let sourceHashes = [
        "UnicodeData.txt": "2fc713e6a31a87c4850a37fe2caffa4218180fadb5de86b43a143ddb4581fb86",
        "CaseFolding.txt": "4e55acfdc32825a22e87670e9056a3bf94ad7c5400065778e9e10f8314372bcf",
        "DerivedNormalizationProps.txt": "8875dccee2bc1a7c1fe568a3b502a9e78c9e0495afd96b6568b4294d0ed1f7e1",
        "NormalizationTest.txt": "871238e37e3be0696ec2bd0891119a041b052da1a84485eda05a5438724b223e"]
    static let sourcePrefix = "https://www.unicode.org/Public/15.1.0/ucd/"

    static func data(_ name: String, _ resources: [String: Data]) throws -> Data {
        guard let data = resources[name] else { throw UnicodeTables.LoadError.missingResource(name) }
        return data
    }
    static func unicode(_ resources: [String: Data]) throws -> UnicodeTables {
        let bytes = try data("unicode-15.1.0.json", resources)
        try require(try data("unicode-15.1.0.json.sha256", resources) == Data((tableHash + "\n").utf8), "Unicode sidecar")
        let source = try LanguageJSON.parse(data("unicode-sources-v1.json", resources))
        try source.checkKeys(["format", "unicodeVersion", "normalizationTablesVersion", "archive", "files",
                              "license", "tableSha256", "normalizationRows"])
        try require(try source.field("format").integer() == 1
            && source.field("unicodeVersion").string() == "15.1.0"
            && source.field("normalizationTablesVersion").string() == UnicodeTables.normalizationVersion
            && source.field("tableSha256").string() == tableHash
            && source.field("normalizationRows").integer() == 19_074, "Unicode source version")
        let archive = try source.field("archive")
        try archive.checkKeys(["url", "sha256"])
        try require(try archive.field("url").string() == "https://www.unicode.org/Public/zipped/15.1.0/UCD.zip"
            && archive.field("sha256").string() == "cb1c663d053926500cd501229736045752713a066bd75802098598b7a7056177", "Unicode archive")
        let files = try source.field("files").array()
        try require(files.count == 4, "Unicode source count")
        var seen = Set<String>()
        for file in files {
            try file.checkKeys(["name", "url", "sha256"])
            let name = try file.field("name").string()
            guard let hash = sourceHashes[name] else { throw LanguageJSON.Invalid.data("unknown Unicode source") }
            try require(seen.insert(name).inserted, "duplicate Unicode source")
            try require(try file.field("url").string() == sourcePrefix + name
                && file.field("sha256").string() == hash, "Unicode source pin")
        }
        let license = try source.field("license")
        try license.checkKeys(["url", "sha256", "retrievedAt", "licenseId"])
        try require(try license.field("url").string() == "https://www.unicode.org/license.txt"
            && license.field("licenseId").string() == "Unicode-3.0"
            && license.field("sha256").string() == licenseHash
            && LanguageManifest.validDate(license.field("retrievedAt").string()), "Unicode license metadata")
        try require(try UnicodeTables.sha256(data("UNICODE-LICENSE.txt", resources)) == licenseHash, "Unicode license bytes")
        return try UnicodeTables(data: bytes, expectedSHA256: tableHash)
    }
}

/// The production manifest is checked independently of Foundation decoding.
/// Its integers describe training, so they have larger bounds than inference;
/// sums and rational comparisons below cannot overflow on untrusted metadata.
private enum LanguageManifest {
    typealias JSON = LanguageJSON.Value
    static let maximum: Int64 = 9_007_199_254_740_991
    static let splits = ["train", "validation", "test"]
    static let evaluationSplits = ["validation", "test"]
    static let buckets: [Int64] = [0, 12, 32, 80, 200]
    static let metricNames = ["acceptedError", "csSkConfusion", "foreignAcceptance", "acceptanceCoverage"]

    struct Count {
        let originals: Int64
        let augmented: Int64
        let groups: Int64
        let evaluated: Int64
    }
    struct Support {
        let groups: Int64
        let evaluated: Int64
        let accepted: Int64
    }
    struct Metric {
        let numerator: Int64
        let denominator: Int64
    }
    struct SourceFile {
        let role: String
        let url: String
        let hash: String
    }

    static func string(_ value: JSON, _ field: String) throws -> String { try value.field(field).string() }
    static func array(_ value: JSON, _ field: String) throws -> [JSON] { try value.field(field).array() }
    static func strings(_ value: JSON, _ field: String) throws -> [String] { try array(value, field).map { try $0.string() } }
    static func integer(_ value: JSON, _ field: String, _ range: ClosedRange<Int64> = 0...maximum) throws -> Int64 {
        let number = try value.field(field).integer()
        try require(range.contains(number), "out of range: \(field)")
        return number
    }
    static func oneOf(_ value: JSON, _ field: String, _ choices: [String]) throws -> String {
        let result = try string(value, field)
        try require(choices.contains(result), "invalid \(field)")
        return result
    }
    static func bucket(_ value: JSON, nonzero: Bool = false) throws -> Int64 {
        let result = try integer(value, "bucketStart")
        try require((nonzero ? Array(buckets.dropFirst()) : buckets).contains(result), "bucket start")
        return result
    }
    static func sum<S: Sequence>(_ values: S) throws -> Int64 where S.Element == Int64 {
        try values.reduce(Int64(0)) { a, b in
            let result = a.addingReportingOverflow(b)
            try require(!result.overflow, "metadata sum overflow")
            return result.partialValue
        }
    }
    static func exactStrings(_ a: [String], _ b: [String]) -> Bool { a.map { Array($0.utf8) } == b.map { Array($0.utf8) } }
    static func unique(_ values: [String]) -> Bool { Set(values.map { Array($0.utf8) }).count == values.count }
    static func key(_ parts: [String]) -> [[UInt8]] { parts.map { Array($0.utf8) } }

    static func daysInMonth(year: Int, month: Int) -> Int {
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        return [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
    }

    static func validDate(_ value: String) -> Bool {
        let b = Array(value.utf8)
        guard b.count == 10, b[4] == 45, b[7] == 45,
              b.enumerated().allSatisfy({ $0.offset == 4 || $0.offset == 7 || (48...57).contains($0.element) }) else { return false }
        let year = Int(b[0] - 48) * 1000 + Int(b[1] - 48) * 100 + Int(b[2] - 48) * 10 + Int(b[3] - 48)
        let month = Int(b[5] - 48) * 10 + Int(b[6] - 48)
        let day = Int(b[8] - 48) * 10 + Int(b[9] - 48)
        guard year > 0, (1...12).contains(month) else { return false }
        return (1...daysInMonth(year: year, month: month)).contains(day)
    }
    static func validTimestamp(_ value: String) -> Bool {
        let b = Array(value.utf8)
        guard b.count == 20, b[10] == 84, b[13] == 58, b[16] == 58, b[19] == 90,
              validDate(String(decoding: b[0..<10], as: UTF8.self)),
              [11, 12, 14, 15, 17, 18].allSatisfy({ (48...57).contains(b[$0]) }) else { return false }
        let hour = Int(b[11] - 48) * 10 + Int(b[12] - 48)
        let minute = Int(b[14] - 48) * 10 + Int(b[15] - 48)
        let second = Int(b[17] - 48) * 10 + Int(b[18] - 48)
        guard hour < 24 && minute < 60 && second <= 60 else { return false }
        if second < 60 { return true }
        // Accept RFC 3339 leap-second notation at a UTC month boundary.
        // Offline provenance validation does not consult a live leap schedule.
        let year = Int(b[0] - 48) * 1000 + Int(b[1] - 48) * 100 + Int(b[2] - 48) * 10 + Int(b[3] - 48)
        let month = Int(b[5] - 48) * 10 + Int(b[6] - 48)
        let day = Int(b[8] - 48) * 10 + Int(b[9] - 48)
        return hour == 23 && minute == 59 && day == daysInMonth(year: year, month: month)
    }
    static func rate(_ numerator: Int64, _ denominator: Int64) -> Int64 {
        // Callers validate 0 <= numerator <= denominator and denominator > 0.
        let product = UInt64(numerator).multipliedFullWidth(by: 10_000)
        return Int64(UInt64(denominator).dividingFullWidth(product).quotient)
    }
    static func passesGate(_ metric: Metric, _ limit: UInt64) -> Bool {
        guard metric.denominator > 0 else { return false }
        let left = UInt64(metric.numerator).multipliedFullWidth(by: 10_000)
        let right = UInt64(metric.denominator).multipliedFullWidth(by: limit)
        return left.high < right.high || (left.high == right.high && left.low <= right.low)
    }

    static func validate(_ root: JSON, model: LanguageModel, artifact: Data, resources: [String: Data]) throws {
        let snapshotSkew = try? root.field("snapshotSkew")
        try root.checkKeys(["contract", "version", "modelId", "artifactPath", "artifactSha256", "createdAt", "corpus",
            "negativeLanguages", "environment", "split", "caps", "augmentation", "counts", "exclusions", "minimumSupport",
            "calibration", "support", "metrics", "documentMetrics", "attribution"]
            + (snapshotSkew == nil ? [] : ["snapshotSkew"]))
        if let snapshotSkew { try validateSnapshotSkew(snapshotSkew) }
        let modelID = try string(root, "modelId")
        try require(try string(root, "contract") == "lang-detector-manifest" && integer(root, "version") == 1
            && asciiIdentifier(modelID, punctuation: "._-") && modelID == model.modelId
            && validTimestamp(string(root, "createdAt")), "manifest identity")
        try require(try string(root, "artifactPath") == LanguageBundle.artifactPath
            && string(root, "artifactSha256") == UnicodeTables.sha256(artifact), "artifact integrity/path")
        try validateEnvironment(root.field("environment"))
        try validateSplit(root.field("split"))
        let negatives = try strings(root, "negativeLanguages")
        try require(!negatives.isEmpty && negatives.allSatisfy(isLanguageID) && strictlySorted(negatives)
            && Set(negatives).isDisjoint(with: model.targets) && !negatives.contains("und") && !negatives.contains("mul"), "negative languages")
        let languages = (model.targets + negatives).sorted()
        let sources = try validateCorpus(array(root, "corpus"), languages: languages)
        let attribution = try validateAttribution(root.field("attribution"), model: model, resources: resources)
        try require(Set(attribution.sourceIds) == sources.ids
            // The bundle also redistributes the pinned Unicode tables, so their license is attributed too.
            && Set(attribution.licenseIds.map { Array($0.utf8) }) == sources.licenses.union([Array("Unicode-3.0".utf8)]),
            "corpus attribution references")
        let caps = try validateCaps(array(root, "caps"), languages: languages)
        let counts = try validateCounts(array(root, "counts"), languages: languages, caps: caps)
        try validateAugmentation(array(root, "augmentation"), counts: counts)
        try validateExclusions(array(root, "exclusions"), sourceIDs: sources.ids)
        let support = try validateSupport(array(root, "support"), languages: languages, counts: counts, model: model)
        try validateMinimumSupport(root.field("minimumSupport"))
        try validateCalibration(root.field("calibration"), model: model)
        let metrics = try validateMetrics(array(root, "metrics"), languages: languages, negatives: negatives,
                                           counts: counts, support: support)
        try validateEnabledBuckets(model: model, languages: languages, support: support, metrics: metrics)
        let documentOriginals = try validateDocuments(array(root, "documentMetrics"), originalsBySource: sources.ownedOriginals)
        let selectedOriginals = try sum(counts.values.map(\.originals))
        // An owned source may supply both technical text and documents. Only
        // records counted in document mode are excluded from text support.
        try require(selectedOriginals <= sources.totalOriginals - documentOriginals, "selected records exceed text source originals")
    }

    static func sourceFile(_ value: JSON) throws -> SourceFile {
        try value.checkKeys(["role", "url", "snapshotDate", "sha256", "formatVersion", "records"])
        let role = try oneOf(value, "role", ["sentences", "links", "attribution", "ownedExamples", "unicodeData", "normalizationTest"])
        let url = try string(value, "url")
        let hash = try string(value, "sha256")
        try require(url.hasPrefix("https://") && isSHA256(hash) && validDate(try string(value, "snapshotDate")), "source file")
        _ = try string(value, "formatVersion")
        _ = try integer(value, "records")
        return SourceFile(role: role, url: url, hash: hash)
    }
    static func validateSnapshotSkew(_ value: JSON) throws {
        try value.checkKeys(["missingFromBase", "cc0DetailMismatch", "excludedIdsSha256", "sampleIds"])
        _ = try integer(value, "missingFromBase")
        _ = try integer(value, "cc0DetailMismatch")
        try require(try isSHA256(string(value, "excludedIdsSha256")), "snapshot skew digest")
        let samples = try array(value, "sampleIds")
        try require(samples.count <= 20, "snapshot skew sample count")
        // Sentence IDs use the full nonnegative Int64 range, unlike metadata counts.
        for sample in samples { try require(try sample.integer() >= 0, "snapshot skew sample ID") }
    }
    static func validateEnvironment(_ value: JSON) throws {
        try value.checkKeys(["exporterGitCommit", "commandArguments", "pythonVersion", "dependencies", "normalizationTablesVersion", "unicodeFiles"])
        let revision = try string(value, "exporterGitCommit")
        try require((40...64).contains(revision.utf8.count)
            && revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), "exporter revision")
        try require(try !strings(value, "commandArguments").isEmpty, "command arguments")
        _ = try string(value, "pythonVersion")
        try require(try string(value, "normalizationTablesVersion") == UnicodeTables.normalizationVersion, "manifest normalization version")
        var dependencyNames = Set<[UInt8]>()
        for dependency in try array(value, "dependencies") {
            try dependency.checkKeys(["name", "version"])
            try require(try dependencyNames.insert(Array(string(dependency, "name").utf8)).inserted, "duplicate dependency")
            _ = try string(dependency, "version")
        }
        let files = try array(value, "unicodeFiles")
        try require(files.count == 4, "Unicode manifest files")
        var seen = Set<String>()
        for entry in files {
            let file = try sourceFile(entry)
            guard let match = LanguageBundle.sourceHashes.first(where: { LanguageBundle.sourcePrefix + $0.key == file.url }) else {
                throw LanguageJSON.Invalid.data("unrecognized Unicode source URL")
            }
            try require(seen.insert(match.key).inserted && file.hash == match.value
                && file.role == (match.key == "NormalizationTest.txt" ? "normalizationTest" : "unicodeData"), "Unicode manifest pin")
        }
    }
    static func validateSplit(_ value: JSON) throws {
        try value.checkKeys(["algorithm", "seed", "splitBp", "maxComponentMembers", "oversizedComponents"])
        try require(try string(value, "algorithm") == "translation-components-sha256-v1", "split algorithm")
        _ = try integer(value, "seed")
        let maximumMembers = try integer(value, "maxComponentMembers", 1...maximum)
        let ratios = try value.field("splitBp")
        try ratios.checkKeys(splits)
        let splitValues = try splits.map { try integer(ratios, $0, 1...9998) }
        try require(try sum(splitValues) == 10_000, "split basis points")
        var groups = Set<String>()
        var blockIDs = Set<String>()
        for component in try array(value, "oversizedComponents") {
            try component.checkKeys(["groupId", "memberCount", "blocks"])
            let groupID = try string(component, "groupId")
            let count = try integer(component, "memberCount", 1...maximum)
            try require(isSHA256(groupID) && groups.insert(groupID).inserted && count > maximumMembers, "oversized component")
            let blocks = try array(component, "blocks")
            try require(!blocks.isEmpty, "component blocks")
            var sizes: [Int64] = []
            for (index, block) in blocks.enumerated() {
                try block.checkKeys(["groupId", "memberCount"])
                let blockID = try string(block, "groupId")
                let size = try integer(block, "memberCount", 1...maximumMembers)
                try require(isSHA256(blockID) && blockIDs.insert(blockID).inserted && blockID != groupID
                    && (index == blocks.count - 1 || size == maximumMembers), "component block")
                sizes.append(size)
            }
            try require(try sum(sizes) == count, "component member reconciliation")
        }
        try require(groups.isDisjoint(with: blockIDs), "component and block IDs overlap")
    }

    struct Corpus {
        let ids: Set<String>
        let licenses: Set<[UInt8]>
        let ownedOriginals: [String: Int64]
        let totalOriginals: Int64
    }
    static func validateCorpus(_ entries: [JSON], languages: [String]) throws -> Corpus {
        try require(!entries.isEmpty, "missing corpus")
        var ids = Set<String>(), mapped = Set<String>()
        var ownedOriginals: [String: Int64] = [:]
        var licenses = Set<[UInt8]>()
        var originals: [Int64] = []
        for entry in entries {
            try entry.checkKeys(["id", "files", "licenseIds", "licenseSelectionPolicy", "languageSelectionPolicy",
                "deduplicationPolicy", "translationGroupPolicy", "originalRecords", "languageMappings"])
            let id = try string(entry, "id")
            try require(asciiIdentifier(id, punctuation: "_-") && ids.insert(id).inserted, "corpus ID")
            let files = try array(entry, "files")
            try require(!files.isEmpty, "corpus files")
            var fileKeys = Set<[[UInt8]]>()
            var owned = false
            for row in files {
                let file = try sourceFile(row)
                try require(fileKeys.insert(key([file.role, file.url])).inserted, "duplicate source file")
                if file.role == "ownedExamples" { owned = true }
            }
            let sourceLicenses = try strings(entry, "licenseIds")
            try require(!sourceLicenses.isEmpty && sourceLicenses.allSatisfy { !$0.isEmpty } && unique(sourceLicenses), "source licenses")
            licenses.formUnion(sourceLicenses.map { Array($0.utf8) })
            for policy in ["licenseSelectionPolicy", "languageSelectionPolicy", "deduplicationPolicy", "translationGroupPolicy"] {
                _ = try string(entry, policy)
            }
            let originalCount = try integer(entry, "originalRecords")
            if owned { ownedOriginals[id] = originalCount }
            originals.append(originalCount)
            let mappings = try array(entry, "languageMappings")
            try require(!mappings.isEmpty, "source language mappings")
            var sourceLanguages = Set<[UInt8]>()
            for mapping in mappings {
                try mapping.checkKeys(["sourceLanguage", "detectorLanguage"])
                let code = try string(mapping, "sourceLanguage")
                let language = try string(mapping, "detectorLanguage")
                try require(!code.isEmpty && sourceLanguages.insert(Array(code.utf8)).inserted && isLanguageID(language), "language mapping")
                if owned && ["und", "mul"].contains(language) { continue }
                try require(languages.contains(language), "unadmitted mapped language")
                if !owned { mapped.insert(language) }
            }
        }
        try require(mapped == Set(languages), "incomplete language mappings")
        return Corpus(ids: ids, licenses: licenses, ownedOriginals: ownedOriginals, totalOriginals: try sum(originals))
    }

    static func validateAttribution(_ value: JSON, model: LanguageModel, resources: [String: Data]) throws -> LanguageAttribution {
        try value.checkKeys(LanguageAttribution.keys)
        let attribution = try LanguageAttribution(sourceIds: strings(value, "sourceIds"), licenseIds: strings(value, "licenseIds"),
            attributionPath: string(value, "attributionPath"), attributionSha256: string(value, "attributionSha256"),
            noticePath: string(value, "noticePath"), noticeSha256: string(value, "noticeSha256"))
        try attribution.validate(production: true)
        try require(exactStrings(attribution.sourceIds, model.attribution.sourceIds)
            && exactStrings(attribution.licenseIds, model.attribution.licenseIds)
            && attribution.attributionPath == "tools/lang/ATTRIBUTION.md" && attribution.noticePath == "NOTICE"
            && attribution.attributionPath == model.attribution.attributionPath && attribution.noticePath == model.attribution.noticePath
            && attribution.attributionSha256 == model.attribution.attributionSha256
            && attribution.noticeSha256 == model.attribution.noticeSha256, "manifest/artifact attribution")
        try require(try UnicodeTables.sha256(LanguageBundle.data("ATTRIBUTION.md", resources)) == attribution.attributionSha256
            && UnicodeTables.sha256(LanguageBundle.data("NOTICE", resources)) == attribution.noticeSha256, "attribution bytes")
        return attribution
    }

    static func validateCaps(_ entries: [JSON], languages: [String]) throws -> [[String]: Int64] {
        var caps: [[String]: Int64] = [:]
        for entry in entries {
            try entry.checkKeys(["split", "language", "maxOriginalRecords"])
            let split = try oneOf(entry, "split", splits)
            let language = try oneOf(entry, "language", languages)
            let cap = try integer(entry, "maxOriginalRecords")
            try require(caps.updateValue(cap, forKey: [split, language]) == nil, "duplicate cap")
        }
        try require(caps.count == splits.count * languages.count, "incomplete caps")
        return caps
    }
    static func validateCounts(_ entries: [JSON], languages: [String], caps: [[String]: Int64]) throws -> [[String]: Count] {
        var counts: [[String]: Count] = [:]
        for entry in entries {
            try entry.checkKeys(["split", "language", "bucketStart", "originals", "augmented", "originalGroups"])
            let split = try oneOf(entry, "split", splits)
            let language = try oneOf(entry, "language", languages)
            let start = try bucket(entry)
            let originals = try integer(entry, "originals"), augmented = try integer(entry, "augmented")
            let groups = try integer(entry, "originalGroups")
            let evaluated = try sum([originals, augmented])
            try require(groups <= evaluated && ((evaluated == 0) == (groups == 0)), "count group reconciliation")
            let count = Count(originals: originals, augmented: augmented, groups: groups, evaluated: evaluated)
            try require(counts.updateValue(count, forKey: [split, language, String(start)]) == nil, "duplicate count")
        }
        try require(counts.count == splits.count * languages.count * buckets.count, "incomplete counts")
        for split in splits {
            for language in languages {
                let originals = try sum(buckets.map { counts[[split, language, String($0)]]?.originals ?? 0 })
                guard let cap = caps[[split, language]] else { throw LanguageJSON.Invalid.data("missing cap") }
                try require(originals <= cap, "original count exceeds cap")
                // A prefix can move to another bucket, but cannot create an
                // independent group beyond the originals of this split/language.
                for start in buckets {
                    try require((counts[[split, language, String(start)]]?.groups ?? 0) <= originals,
                                "augmented examples inflate original groups")
                }
            }
        }
        return counts
    }
    static func validateAugmentation(_ entries: [JSON], counts: [[String]: Count]) throws {
        try require(!entries.isEmpty, "augmentation rules")
        var algorithms = Set<String>()
        var outputCounts: [Int64] = []
        var outputsPerOriginal: [String: UInt64] = [:]
        for entry in entries {
            try entry.checkKeys(["algorithm", "splits", "lengths", "inputCount", "outputCount"])
            let algorithm = try oneOf(entry, "algorithm", ["none-v1", "scalar-prefix-v1", "strip-marks-v1", "concat-v1"])
            try require(algorithms.insert(algorithm).inserted, "duplicate augmentation rule")
            let selectedSplits = try strings(entry, "splits")
            try require((1...3).contains(selectedSplits.count) && unique(selectedSplits)
                && selectedSplits.allSatisfy { splits.contains($0) }, "augmentation splits")
            let lengths = try array(entry, "lengths").map { try $0.integer() }
            // Prefixes and concat-v1 anchors emit at most one example per original and length.
            if algorithm == "scalar-prefix-v1" || algorithm == "concat-v1" {
                try require(lengths.allSatisfy { (1...5_000_000).contains($0) }
                    && strictlySorted(lengths), "augmentation lengths")
            } else { try require(lengths.isEmpty, "unexpected augmentation lengths") }
            let input = try integer(entry, "inputCount"), output = try integer(entry, "outputCount")
            let originals = try sum(counts.filter { selectedSplits.contains($0.key[0]) }.values.map(\.originals))
            try require(input == originals, "augmentation input reconciliation")
            if algorithm == "none-v1" { try require(entries.count == 1 && output == 0, "none augmentation") }
            else {
                let multiplier = algorithm == "strip-marks-v1" ? UInt64(1) : UInt64(lengths.count)
                let maximumOutput = UInt64(input).multipliedFullWidth(by: multiplier)
                try require(maximumOutput.high > 0 || UInt64(output) <= maximumOutput.low, "augmentation output bounds")
                for split in selectedSplits { outputsPerOriginal[split, default: 0] += multiplier }
            }
            outputCounts.append(output)
        }
        try require(try sum(outputCounts) == sum(counts.values.map(\.augmented)), "augmentation output reconciliation")
        for pair in Set(counts.keys.map { Array($0.prefix(2)) }) {
            let rows = counts.filter { Array($0.key.prefix(2)) == pair }.values
            let originals = try sum(rows.map(\.originals))
            let augmented = try sum(rows.map(\.augmented))
            let limit = UInt64(originals).multipliedFullWidth(by: outputsPerOriginal[pair[0], default: 0])
            try require(limit.high > 0 || UInt64(augmented) <= limit.low, "augmentation split/language reconciliation")
        }
    }
    static func validateExclusions(_ entries: [JSON], sourceIDs: Set<String>) throws {
        var seen = Set<[[UInt8]]>()
        for entry in entries {
            try entry.checkKeys(["sourceId", "split", "language", "reason", "count"])
            let source = try string(entry, "sourceId"), split = try oneOf(entry, "split", splits)
            let language = try string(entry, "language"), reason = try string(entry, "reason")
            try require(sourceIDs.contains(source) && seen.insert(key([source, split, language, reason])).inserted, "exclusion references/keys")
            _ = try integer(entry, "count")
        }
    }
    static func validateSupport(_ entries: [JSON], languages: [String], counts: [[String]: Count], model: LanguageModel) throws -> [[String]: Support] {
        var support: [[String]: Support] = [:]
        for entry in entries {
            try entry.checkKeys(["split", "bucketStart", "language", "originalGroups", "evaluated", "accepted"])
            let split = try oneOf(entry, "split", evaluationSplits), language = try oneOf(entry, "language", languages)
            let start = try bucket(entry, nonzero: true)
            let groups = try integer(entry, "originalGroups"), evaluated = try integer(entry, "evaluated"), accepted = try integer(entry, "accepted")
            let key = [split, language, String(start)]
            guard let count = counts[key], let threshold = model.thresholds.first(where: { $0.start == start }) else {
                throw LanguageJSON.Invalid.data("support count reference")
            }
            try require(groups == count.groups && evaluated == count.evaluated && accepted <= evaluated
                && (threshold.enabled == 1 || accepted == 0), "support/count reconciliation")
            try require(support.updateValue(Support(groups: groups, evaluated: evaluated, accepted: accepted), forKey: key) == nil, "duplicate support")
        }
        try require(support.count == evaluationSplits.count * languages.count * (buckets.count - 1), "incomplete support")
        return support
    }
    static func validateMinimumSupport(_ value: JSON) throws {
        let minima: [String: Int64] = ["groupsPerTarget": 200, "groupsPerNegativeLanguage": 200, "acceptedTotal": 1000,
                                      "acceptedTrueCs": 100, "acceptedTrueSk": 100]
        try value.checkKeys(Array(minima.keys))
        for (field, required) in minima { try require(try integer(value, field) == required, "minimum support") }
    }
    static func validateCalibration(_ value: JSON, model: LanguageModel) throws {
        try value.checkKeys(["algorithm", "candidates", "tieBreak", "disabledBuckets"])
        try require(try string(value, "algorithm") == "grid-max-accepted-v1"
            && exactStrings(strings(value, "tieBreak"), ["minWinningScoreDescending", "minMarginDescending", "minKnownCoverageBpDescending"]), "calibration algorithm")
        let candidates = try array(value, "candidates")
        try require(candidates.count == 4, "calibration bucket count")
        for (index, candidate) in candidates.enumerated() {
            try candidate.checkKeys(["bucketStart", "minWinningScores", "minMargins", "minKnownCoverageBp"])
            let start = try bucket(candidate, nonzero: true)
            try require(start == buckets[index + 1], "candidate bucket order")
            let scores = try array(candidate, "minWinningScores").map { try $0.integer() }
            let margins = try array(candidate, "minMargins").map { try $0.integer() }
            let coverage = try array(candidate, "minKnownCoverageBp").map { try $0.integer() }
            try require(!scores.isEmpty && scores.allSatisfy { (-7_000_000...0).contains($0) } && strictlySorted(scores)
                && !margins.isEmpty && margins.allSatisfy { (1...7_000_000).contains($0) } && strictlySorted(margins)
                && !coverage.isEmpty && coverage.allSatisfy { (0...10_000).contains($0) } && strictlySorted(coverage), "candidate grids")
            let threshold = model.thresholds[index]
            if threshold.enabled == 1 {
                try require(scores.contains(threshold.minWinningScore) && margins.contains(threshold.minMargin)
                    && coverage.contains(threshold.minKnownCoverageBp), "threshold not from candidate grid")
            }
        }
        var disabled = Set<Int64>()
        for entry in try array(value, "disabledBuckets") {
            try entry.checkKeys(["bucketStart", "reason"])
            let start = try bucket(entry, nonzero: true)
            _ = try string(entry, "reason")
            try require(disabled.insert(start).inserted, "duplicate disabled bucket")
        }
        try require(disabled == Set(model.thresholds.filter { $0.enabled == 0 }.map { Int64($0.start) }), "disabled bucket reconciliation")
    }

    static func validateMetrics(_ entries: [JSON], languages: [String], negatives: [String], counts: [[String]: Count],
                                support: [[String]: Support]) throws -> [[String]: Metric] {
        var metrics: [[String]: Metric] = [:]
        for entry in entries {
            try entry.checkKeys(["split", "bucketStart", "language", "name", "numerator", "denominator", "rateBp"])
            let split = try oneOf(entry, "split", evaluationSplits), start = try bucket(entry)
            let language = try oneOf(entry, "language", languages + ["all"]), name = try oneOf(entry, "name", metricNames)
            let numerator = try integer(entry, "numerator"), denominator = try integer(entry, "denominator")
            try require(numerator <= denominator, "metric numerator")
            let reported = try entry.field("rateBp")
            if denominator == 0 { try require(reported == .null, "empty metric rate") }
            else { try require(try reported.integer() == rate(numerator, denominator), "metric integer rate") }
            try require(metrics.updateValue(Metric(numerator: numerator, denominator: denominator),
                forKey: [split, language, String(start), name]) == nil, "duplicate metric")
        }
        try require(metrics.count == evaluationSplits.count * (languages.count + 1) * buckets.count * metricNames.count, "incomplete metrics")
        for split in evaluationSplits {
            for start in buckets {
                for language in languages {
                    let key = [split, language, String(start)]
                    guard let count = counts[key] else { throw LanguageJSON.Invalid.data("metric count reference") }
                    let accepted = start == 0 ? 0 : support[key]?.accepted ?? 0
                    for name in metricNames {
                        guard let metric = metrics[key + [name]] else { throw LanguageJSON.Invalid.data("missing metric") }
                        switch name {
                        case "acceptanceCoverage":
                            try require(metric.numerator == accepted && metric.denominator == count.evaluated, "coverage reconciliation")
                        case "acceptedError":
                            try require(metric.denominator == accepted
                                && (!negatives.contains(language) || metric.numerator == accepted), "accepted error reconciliation")
                        case "csSkConfusion":
                            let eligible = language == "cs" || language == "sk"
                            try require(metric.denominator == (eligible ? accepted : 0), "confusion denominator")
                            guard let error = metrics[key + ["acceptedError"]] else { throw LanguageJSON.Invalid.data("missing error metric") }
                            try require(metric.numerator <= error.numerator, "confusion/error reconciliation")
                        case "foreignAcceptance":
                            let negative = negatives.contains(language)
                            try require(metric.numerator == (negative ? accepted : 0)
                                && metric.denominator == (negative ? count.evaluated : 0), "foreign acceptance reconciliation")
                        default: throw LanguageJSON.Invalid.data("unknown metric")
                        }
                    }
                }
                for name in metricNames {
                    guard let all = metrics[[split, "all", String(start), name]] else { throw LanguageJSON.Invalid.data("missing aggregate metric") }
                    let rows = try languages.map { language -> Metric in
                        guard let metric = metrics[[split, language, String(start), name]] else { throw LanguageJSON.Invalid.data("missing per-language metric") }
                        return metric
                    }
                    try require(try all.numerator == sum(rows.map(\.numerator)) && all.denominator == sum(rows.map(\.denominator)), "aggregate metric reconciliation")
                }
            }
        }
        return metrics
    }
    static func validateEnabledBuckets(model: LanguageModel, languages: [String], support: [[String]: Support], metrics: [[String]: Metric]) throws {
        for threshold in model.thresholds where threshold.enabled == 1 {
            let start = String(threshold.start)
            for split in evaluationSplits {
                let rows = try languages.map { language -> Support in
                    guard let row = support[[split, language, start]] else { throw LanguageJSON.Invalid.data("missing enabled support") }
                    return row
                }
                try require(rows.allSatisfy { $0.groups >= 200 } && (try sum(rows.map(\.accepted))) >= 1000
                    && (support[[split, "cs", start]]?.accepted ?? 0) >= 100
                    && (support[[split, "sk", start]]?.accepted ?? 0) >= 100, "enabled bucket support")
                for (name, limit) in [("acceptedError", UInt64(200)), ("csSkConfusion", UInt64(100)), ("foreignAcceptance", UInt64(100))] {
                    guard let metric = metrics[[split, "all", start, name]] else { throw LanguageJSON.Invalid.data("missing gate metric") }
                    try require(passesGate(metric, limit), "enabled bucket release gate")
                }
            }
        }
    }
    static func validateDocuments(_ entries: [JSON], originalsBySource: [String: Int64]) throws -> Int64 {
        var seen = Set<[[UInt8]]>()
        var counts: [String: Int64] = [:]
        for entry in entries {
            try entry.checkKeys(["sourceId", "goldLabel", "predictedLabel", "count"])
            let source = try string(entry, "sourceId")
            let gold = try oneOf(entry, "goldLabel", ["cs", "de", "en", "sk", "mixed", "und"])
            let predicted = try oneOf(entry, "predictedLabel", ["cs", "de", "en", "sk", "mixed", "und"])
            try require(originalsBySource[source] != nil && seen.insert(key([source, gold, predicted])).inserted, "document source/key")
            counts[source] = try sum([counts[source, default: 0], integer(entry, "count")])
        }
        for (source, originals) in originalsBySource {
            try require(counts[source, default: 0] <= originals, "document source count reconciliation")
        }
        return try sum(counts.values)
    }
}
