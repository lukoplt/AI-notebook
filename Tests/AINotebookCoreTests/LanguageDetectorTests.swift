import Foundation
import XCTest
@testable import AINotebookCore

final class LanguageDetectorTests: XCTestCase {
    func testUnavailablePreservesNull() {
        let detector = LanguageDetector.load { _ in throw CocoaError(.fileReadNoSuchFile) }
        XCTAssertFalse(detector.isAvailable)
        XCTAssertFalse(LanguageDetector.unavailable.isAvailable)
        XCTAssertNil(detector.detectText("Toto je dostatečně dlouhý český text."))
        XCTAssertNil(detector.detectText(utf16Units: [65]))
        XCTAssertNil(detector.detectDocument("This is a complete document."))
        XCTAssertNil(detector.detectDocument(utf16Units: [65]))
        XCTAssertEqual(ChunkLanguage.resolve(label: nil, reason: nil, documentLabel: "cs"),
                       ChunkLanguage(lang: nil, langInherited: false))
    }

    func testEveryInheritanceCase() throws {
        let fixture = try SharedFixtures.json("contracts/lang-inheritance-v1.json")
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 16)
        for c in cases {
            let input = try XCTUnwrap(c["input"] as? [String: Any])
            let result = ChunkLanguage.resolve(label: input["label"] as? String,
                reason: input["reason"] as? String, documentLabel: input["documentLabel"] as? String)
            try assertLanguageJSON(result, equals: XCTUnwrap(c["expected"]), try XCTUnwrap(c["name"] as? String))
        }
    }

    func testEverySharedLoadingCase() throws {
        let original = try loadingResources()
        let fixture = try SharedFixtures.json("contracts/lang-loading-v1.json")
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 77)
        for c in cases {
            let name = try XCTUnwrap(c["name"] as? String)
            let input = try XCTUnwrap(c["input"] as? [String: Any])
            var resources = original
            switch c["operation"] as? String {
            case "unchanged": break
            case "removeResource": resources.removeValue(forKey: try XCTUnwrap(input["resource"] as? String))
            case "flipByte":
                let resource = try XCTUnwrap(input["resource"] as? String)
                let index = try XCTUnwrap(input["byteIndex"] as? Int)
                var bytes = try XCTUnwrap(resources[resource])
                bytes[index] ^= 1
                resources[resource] = bytes
            case "setManifestValue", "addUnknownManifestKey":
                let resource = try XCTUnwrap(input["resource"] as? String)
                let object = try JSONSerialization.jsonObject(with: XCTUnwrap(resources[resource]))
                let pointer = try XCTUnwrap(input["pointer"] as? String)
                let patched = try replacing(object, at: pointer.split(separator: "/").map(String.init)[...],
                                            with: XCTUnwrap(input["value"]))
                resources[resource] = try jsonBytes(patched)
            case "setResourceValues":
                for change in try XCTUnwrap(input["changes"] as? [[String: Any]]) {
                    let resource = try XCTUnwrap(change["resource"] as? String)
                    let object = try JSONSerialization.jsonObject(with: XCTUnwrap(resources[resource]))
                    let pointer = try XCTUnwrap(change["pointer"] as? String)
                    let patched = try replacing(object, at: pointer.split(separator: "/").map(String.init)[...],
                                                with: XCTUnwrap(change["value"]))
                    resources[resource] = try jsonBytes(patched)
                }
                if input["refreshArtifactDigest"] as? Bool == true {
                    let artifact = try XCTUnwrap(resources["lang-detector-v1.json"])
                    let manifest = try JSONSerialization.jsonObject(with: XCTUnwrap(resources["lang-detector-v1.manifest.json"]))
                    resources["lang-detector-v1.manifest.json"] = try jsonBytes(replacing(manifest,
                        at: ["artifactSha256"][...], with: UnicodeTables.sha256(artifact)))
                }
            case "duplicateManifestKey":
                let resource = try XCTUnwrap(input["resource"] as? String)
                let data = try XCTUnwrap(resources[resource])
                resources[resource] = Data("{\"version\":1,".utf8) + data.dropFirst()
            case "replaceArtifactWithSynthetic":
                let model = try XCTUnwrap(SharedFixtures.json("contracts/lang-score-v1.json")["model"])
                let data = try jsonBytes(model)
                resources["lang-detector-v1.json"] = data
                let manifest = try JSONSerialization.jsonObject(with: XCTUnwrap(resources["lang-detector-v1.manifest.json"]))
                resources["lang-detector-v1.manifest.json"] = try jsonBytes(replacing(manifest,
                    at: ["artifactSha256"][...], with: UnicodeTables.sha256(data)))
            default: XCTFail("unknown operation: \(name)"); continue
            }
            let expected = try XCTUnwrap(c["expected"] as? [String: Any])
            let snapshot = resources
            let detector = LanguageDetector.load { resource in
                guard let data = snapshot[resource] else { throw CocoaError(.fileReadNoSuchFile) }
                return data
            }
            XCTAssertEqual(detector.isAvailable, expected["isAvailable"] as? Bool, name)
            if !detector.isAvailable { XCTAssertNil(detector.detectText("aaaa aaaa aaaa"), name) }
        }
    }

    func testManifestRejectsSchemaAndProvenanceInconsistencies() throws {
        let original = try loadingResources()
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(original["lang-detector-v1.manifest.json"])) as? [String: Any])
        let caps = try XCTUnwrap(manifest["caps"] as? [Any])
        let mutations: [(String, Any)] = [
            ("/environment/dependencies", [["name": "x", "version": "1", "unexpected": 0]]),
            ("/environment/exporterGitCommit", String(repeating: "0", count: 39)),
            ("/corpus/0/files/0/snapshotDate", "2025-02-29"),
            ("/corpus/0/languageMappings/1/sourceLanguage", "ces"),
            ("/corpus/0/id", "unattributed-source"),
            ("/corpus/0/licenseIds", ["unattributed-license"]),
            ("/negativeLanguages", ["fr", "fr"]),
            ("/split/splitBp/train", 7999),
            ("/split/seed", Int64(9_007_199_254_740_992)),
            ("/caps", Array(caps.dropLast())),
            ("/counts/0/originalGroups", 1),
            ("/support/0/evaluated", 1),
            ("/metrics/0/rateBp", 0),
            ("/metrics/0/numerator", 1),
            ("/metrics/0", ["split": "validation", "bucketStart": 0, "language": "cs", "name": "acceptedError",
                             "numerator": Int64(9_007_199_254_740_991), "denominator": Int64(9_007_199_254_740_991), "rateBp": 10000]),
            ("/calibration/candidates/0/minMargins", [2, 1]),
            ("/calibration/disabledBuckets", []),
            ("/calibration/tieBreak", ["minWinningScoreDescending", "minMarginDescending", "minKnownCoverageBpDescending"]),
            ("/augmentation/0/lengths", [1]),
            ("/augmentation/0/splits", ["train", "train"]),
            ("/minimumSupport/groupsPerTarget", 199),
            ("/documentMetrics", [["sourceId": "unknown", "goldLabel": "mixed", "predictedLabel": "und", "count": 1]])
        ]
        for (pointer, value) in mutations {
            var resources = original
            resources["lang-detector-v1.manifest.json"] = try jsonBytes(replacing(manifest,
                at: pointer.split(separator: "/").map(String.init)[...], with: value))
            let snapshot = resources
            XCTAssertFalse(LanguageDetector.load { try XCTUnwrap(snapshot[$0]) }.isAvailable, pointer)
        }
    }

    func testManifestModelIdentityRequiresASCII() throws {
        var resources = try loadingResources()
        var model = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(resources["lang-detector-v1.json"])) as? [String: Any])
        model["modelId"] = "K"
        let artifact = try jsonBytes(model)
        resources["lang-detector-v1.json"] = artifact
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(resources["lang-detector-v1.manifest.json"])) as? [String: Any])
        manifest["artifactSha256"] = UnicodeTables.sha256(artifact)
        manifest["modelId"] = "K"
        resources["lang-detector-v1.manifest.json"] = try jsonBytes(manifest)
        let valid = resources
        XCTAssertTrue(LanguageDetector.load { try XCTUnwrap(valid[$0]) }.isAvailable)
        manifest["modelId"] = "K"
        resources["lang-detector-v1.manifest.json"] = try jsonBytes(manifest)
        let invalid = resources
        XCTAssertFalse(LanguageDetector.load { try XCTUnwrap(invalid[$0]) }.isAvailable)
    }

    func testManifestUTCDateAndLeapSecondNotation() throws {
        let original = try loadingResources()
        let manifest = try JSONSerialization.jsonObject(with: XCTUnwrap(original["lang-detector-v1.manifest.json"]))
        let cases = [("2024-02-29T23:59:59Z", true), ("2016-12-31T23:59:60Z", true),
                     ("2025-02-29T00:00:00Z", false), ("2024-02-29T24:00:00Z", false),
                     ("2016-12-31T23:59:61Z", false), ("2016-12-31T12:00:60Z", false),
                     ("2016-12-30T23:59:60Z", false),
                     ("2024-02-29T23:59:59+00:00", false)]
        for (timestamp, valid) in cases {
            var resources = original
            resources["lang-detector-v1.manifest.json"] = try jsonBytes(replacing(manifest,
                at: ["createdAt"][...], with: timestamp))
            XCTAssertEqual(LanguageDetector.load { try XCTUnwrap(resources[$0]) }.isAvailable, valid, timestamp)
        }
    }

    func testConsistentNonzeroCountsWithDisabledBucketsLoad() throws {
        let resources = try nonzeroTextResources()
        XCTAssertTrue(LanguageDetector.load { try XCTUnwrap(resources[$0]) }.isAvailable)
    }

    func testEnabledBucketRequiresExactValidationAndTestErrorGate() throws {
        let valid = try enabledBucketResources()
        XCTAssertTrue(LanguageDetector.load { try XCTUnwrap(valid[$0]) }.isAvailable,
                      "20 errors among 1000 accepted predictions meets the 200 bp gate")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(valid["lang-detector-v1.manifest.json"])) as? [String: Any])
        for split in ["validation", "test"] {
            var changed = manifest
            var metrics = try XCTUnwrap(changed["metrics"] as? [[String: Any]])
            for i in metrics.indices where metrics[i]["split"] as? String == split
                && metrics[i]["bucketStart"] as? Int == 12 && metrics[i]["name"] as? String == "acceptedError"
                && ["de", "all"].contains(metrics[i]["language"] as? String ?? "") {
                metrics[i]["numerator"] = 21
                metrics[i]["rateBp"] = 10_000 * 21 / (try XCTUnwrap(metrics[i]["denominator"] as? Int))
            }
            changed["metrics"] = metrics
            var invalid = valid
            invalid["lang-detector-v1.manifest.json"] = try jsonBytes(changed)
            XCTAssertFalse(LanguageDetector.load { try XCTUnwrap(invalid[$0]) }.isAvailable,
                           "21 errors among 1000 accepted predictions must fail the \(split) gate")
        }
    }

    /// Enables one bucket with independent support for every target and negative
    /// language; all other buckets retain the shared fixture's empty counts.
    private func enabledBucketResources() throws -> [String: Data] {
        var resources = try loadingResources()
        var model = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(resources["lang-detector-v1.json"])) as? [String: Any])
        let targets = try XCTUnwrap(model["targets"] as? [String])
        var thresholds = try XCTUnwrap(model["thresholds"] as? [[String: Any]])
        thresholds[0]["enabled"] = 1
        model["thresholds"] = thresholds
        let artifact = try jsonBytes(model)
        resources["lang-detector-v1.json"] = artifact
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(resources["lang-detector-v1.manifest.json"])) as? [String: Any])
        manifest["artifactSha256"] = UnicodeTables.sha256(artifact)
        let negatives = try XCTUnwrap(manifest["negativeLanguages"] as? [String])
        let acceptedTotal = targets.count * 250
        let negativeTotal = negatives.count * 200
        let evaluatedTotal = acceptedTotal + negativeTotal
        var corpus = try XCTUnwrap(manifest["corpus"] as? [[String: Any]])
        corpus[0]["originalRecords"] = 2 * evaluatedTotal
        var files = try XCTUnwrap(corpus[0]["files"] as? [[String: Any]])
        files[0]["records"] = 2 * evaluatedTotal
        corpus[0]["files"] = files
        manifest["corpus"] = corpus
        var caps = try XCTUnwrap(manifest["caps"] as? [[String: Any]])
        for i in caps.indices where caps[i]["split"] as? String != "train" {
            caps[i]["maxOriginalRecords"] = targets.contains(caps[i]["language"] as? String ?? "") ? 250 : 200
        }
        manifest["caps"] = caps
        var counts = try XCTUnwrap(manifest["counts"] as? [[String: Any]])
        for i in counts.indices where counts[i]["split"] as? String != "train" && counts[i]["bucketStart"] as? Int == 12 {
            let originals = targets.contains(counts[i]["language"] as? String ?? "") ? 250 : 200
            counts[i]["originals"] = originals
            counts[i]["originalGroups"] = originals
        }
        manifest["counts"] = counts
        var augmentation = try XCTUnwrap(manifest["augmentation"] as? [[String: Any]])
        augmentation[0]["inputCount"] = 2 * evaluatedTotal
        manifest["augmentation"] = augmentation
        var support = try XCTUnwrap(manifest["support"] as? [[String: Any]])
        for i in support.indices where support[i]["bucketStart"] as? Int == 12 {
            let target = targets.contains(support[i]["language"] as? String ?? "")
            support[i]["originalGroups"] = target ? 250 : 200
            support[i]["evaluated"] = target ? 250 : 200
            support[i]["accepted"] = target ? 250 : 0
        }
        manifest["support"] = support
        var calibration = try XCTUnwrap(manifest["calibration"] as? [String: Any])
        calibration["disabledBuckets"] = try XCTUnwrap(calibration["disabledBuckets"] as? [[String: Any]])
            .filter { $0["bucketStart"] as? Int != 12 }
        manifest["calibration"] = calibration
        var metrics = try XCTUnwrap(manifest["metrics"] as? [[String: Any]])
        for i in metrics.indices where metrics[i]["bucketStart"] as? Int == 12 {
            let language = try XCTUnwrap(metrics[i]["language"] as? String)
            let accepted = language == "all" ? acceptedTotal : (targets.contains(language) ? 250 : 0)
            var numerator = 0, denominator = 0
            switch metrics[i]["name"] as? String {
            case "acceptedError":
                numerator = ["de", "all"].contains(language) ? 20 : 0
                denominator = accepted
            case "csSkConfusion": denominator = language == "all" ? 500 : (["cs", "sk"].contains(language) ? 250 : 0)
            case "foreignAcceptance": denominator = language == "all" ? negativeTotal : (negatives.contains(language) ? 200 : 0)
            case "acceptanceCoverage":
                numerator = accepted
                denominator = language == "all" ? evaluatedTotal : (targets.contains(language) ? 250 : 200)
            default: XCTFail("unknown fixture metric")
            }
            metrics[i]["numerator"] = numerator
            metrics[i]["denominator"] = denominator
            if denominator == 0 { metrics[i]["rateBp"] = NSNull() }
            else { metrics[i]["rateBp"] = 10_000 * numerator / denominator }
        }
        manifest["metrics"] = metrics
        resources["lang-detector-v1.manifest.json"] = try jsonBytes(manifest)
        return resources
    }

    func testAugmentationCannotInflateIndependentGroups() throws {
        let valid = try augmentedResources(ruleSplit: "validation", originalGroups: 1)
        XCTAssertTrue(LanguageDetector.load { try XCTUnwrap(valid[$0]) }.isAvailable)
        let invalid = try augmentedResources(ruleSplit: "validation", originalGroups: 2)
        XCTAssertFalse(LanguageDetector.load { try XCTUnwrap(invalid[$0]) }.isAvailable)
    }

    func testAugmentationMustBelongToItsDeclaredSplit() throws {
        let valid = try augmentedResources(ruleSplit: "validation", originalGroups: 1)
        XCTAssertTrue(LanguageDetector.load { try XCTUnwrap(valid[$0]) }.isAvailable)
        let invalid = try augmentedResources(ruleSplit: "train", originalGroups: 1)
        XCTAssertFalse(LanguageDetector.load { try XCTUnwrap(invalid[$0]) }.isAvailable)
    }

    private func nonzeroTextResources() throws -> [String: Data] {
        var resources = try loadingResources()
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(resources["lang-detector-v1.manifest.json"])) as? [String: Any])
        var corpus = try XCTUnwrap(manifest["corpus"] as? [[String: Any]])
        corpus[0]["originalRecords"] = 3
        var files = try XCTUnwrap(corpus[0]["files"] as? [[String: Any]])
        files[0]["records"] = 3
        corpus[0]["files"] = files
        manifest["corpus"] = corpus
        var caps = try XCTUnwrap(manifest["caps"] as? [[String: Any]])
        for i in caps.indices where caps[i]["language"] as? String == "cs" { caps[i]["maxOriginalRecords"] = 1 }
        manifest["caps"] = caps
        var counts = try XCTUnwrap(manifest["counts"] as? [[String: Any]])
        for i in counts.indices where counts[i]["language"] as? String == "cs" && counts[i]["bucketStart"] as? Int == 12 {
            counts[i]["originals"] = 1
            counts[i]["originalGroups"] = 1
        }
        manifest["counts"] = counts
        var augmentation = try XCTUnwrap(manifest["augmentation"] as? [[String: Any]])
        augmentation[0]["inputCount"] = 3
        manifest["augmentation"] = augmentation
        var support = try XCTUnwrap(manifest["support"] as? [[String: Any]])
        for i in support.indices where support[i]["language"] as? String == "cs" && support[i]["bucketStart"] as? Int == 12 {
            support[i]["originalGroups"] = 1
            support[i]["evaluated"] = 1
        }
        manifest["support"] = support
        var metrics = try XCTUnwrap(manifest["metrics"] as? [[String: Any]])
        for i in metrics.indices where metrics[i]["name"] as? String == "acceptanceCoverage"
            && metrics[i]["bucketStart"] as? Int == 12 && ["cs", "all"].contains(metrics[i]["language"] as? String ?? "") {
            metrics[i]["denominator"] = 1
            metrics[i]["rateBp"] = 0
        }
        manifest["metrics"] = metrics
        resources["lang-detector-v1.manifest.json"] = try jsonBytes(manifest)
        return resources
    }

    /// The validation cs bucket has one original plus one derived example.
    /// All mutations start from the shared production-shaped loading fixture.
    private func augmentedResources(ruleSplit: String, originalGroups: Int) throws -> [String: Data] {
        var resources = try nonzeroTextResources()
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(resources["lang-detector-v1.manifest.json"])) as? [String: Any])
        var counts = try XCTUnwrap(manifest["counts"] as? [[String: Any]])
        for i in counts.indices where counts[i]["split"] as? String == "validation"
            && counts[i]["language"] as? String == "cs" && counts[i]["bucketStart"] as? Int == 12 {
            counts[i]["augmented"] = 1
            counts[i]["originalGroups"] = originalGroups
        }
        manifest["counts"] = counts
        var support = try XCTUnwrap(manifest["support"] as? [[String: Any]])
        for i in support.indices where support[i]["split"] as? String == "validation"
            && support[i]["language"] as? String == "cs" && support[i]["bucketStart"] as? Int == 12 {
            support[i]["evaluated"] = 2
            support[i]["originalGroups"] = originalGroups
        }
        manifest["support"] = support
        var metrics = try XCTUnwrap(manifest["metrics"] as? [[String: Any]])
        for i in metrics.indices where metrics[i]["split"] as? String == "validation"
            && metrics[i]["name"] as? String == "acceptanceCoverage" && metrics[i]["bucketStart"] as? Int == 12
            && ["cs", "all"].contains(metrics[i]["language"] as? String ?? "") {
            metrics[i]["denominator"] = 2
        }
        manifest["metrics"] = metrics
        manifest["augmentation"] = [["algorithm": "strip-marks-v1", "splits": [ruleSplit],
                                      "lengths": [], "inputCount": 1, "outputCount": 1]]
        resources["lang-detector-v1.manifest.json"] = try jsonBytes(manifest)
        return resources
    }

    func testOwnedDocumentLabelsStayOutsideTextSupport() throws {
        var resources = try loadingResources()
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(resources["lang-detector-v1.manifest.json"])) as? [String: Any])
        var corpus = try XCTUnwrap(manifest["corpus"] as? [[String: Any]])
        var documentSource = corpus[0]
        documentSource["id"] = "wp1-test-documents"
        documentSource["originalRecords"] = 1
        documentSource["languageMappings"] = [
            ["sourceLanguage": "und", "detectorLanguage": "und"],
            ["sourceLanguage": "mul", "detectorLanguage": "mul"]
        ]
        var files = try XCTUnwrap(documentSource["files"] as? [[String: Any]])
        files[0]["role"] = "ownedExamples"
        files[0]["url"] = "https://example.invalid/wp1-test-document"
        files[0]["records"] = 1
        documentSource["files"] = files
        corpus.append(documentSource)
        manifest["corpus"] = corpus
        manifest["documentMetrics"] = [["sourceId": "wp1-test-documents", "goldLabel": "mixed", "predictedLabel": "und", "count": 1]]
        var attribution = try XCTUnwrap(manifest["attribution"] as? [String: Any])
        attribution["sourceIds"] = ["wp4-loader-test-only", "wp1-test-documents"]
        manifest["attribution"] = attribution
        var model = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(resources["lang-detector-v1.json"])) as? [String: Any])
        model["attribution"] = attribution
        let bytes = try jsonBytes(model)
        resources["lang-detector-v1.json"] = bytes
        manifest["artifactSha256"] = UnicodeTables.sha256(bytes)
        resources["lang-detector-v1.manifest.json"] = try jsonBytes(manifest)
        let snapshot = resources
        XCTAssertTrue(LanguageDetector.load { try XCTUnwrap(snapshot[$0]) }.isAvailable)

        // Another source's records cannot justify nonexistent owned documents.
        corpus[0]["originalRecords"] = 1
        var textFiles = try XCTUnwrap(corpus[0]["files"] as? [[String: Any]])
        textFiles[0]["records"] = 1
        corpus[0]["files"] = textFiles
        corpus[1]["originalRecords"] = 0
        var documentFiles = try XCTUnwrap(corpus[1]["files"] as? [[String: Any]])
        documentFiles[0]["records"] = 0
        corpus[1]["files"] = documentFiles
        manifest["corpus"] = corpus
        resources["lang-detector-v1.manifest.json"] = try jsonBytes(manifest)
        let inconsistent = resources
        XCTAssertFalse(LanguageDetector.load { try XCTUnwrap(inconsistent[$0]) }.isAvailable)
    }

    func testEveryTextFixtureThroughBothFacadeInputs() throws {
        let fixture = try SharedFixtures.json("contracts/lang-score-v1.json")
        let detector = try LanguageDetector(testModelData: jsonBytes(XCTUnwrap(fixture["model"])), tables: UnicodeTables.bundled())
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]]).filter { $0["mode"] as? String == "text" }
        XCTAssertEqual(cases.count, 23)
        for c in cases {
            let input = try XCTUnwrap(c["input"] as? String)
            let result = try XCTUnwrap(detector.detectText(input))
            XCTAssertEqual(result, detector.detectText(utf16Units: Array(input.utf16)))
            try assertLanguageJSON(result, equals: XCTUnwrap(c["expected"]), try XCTUnwrap(c["name"] as? String))
        }
    }

    func testFacadeEnforcesTextCap() throws {
        var model = try XCTUnwrap(SharedFixtures.json("contracts/lang-score-v1.json")["model"] as? [String: Any])
        var parameters = try XCTUnwrap(model["parameters"] as? [String: Any])
        parameters["inputCapScalars"] = 9000
        parameters["textCapScalars"] = 8192
        model["parameters"] = parameters
        let detector = try LanguageDetector(testModelData: jsonBytes(model), tables: UnicodeTables.bundled())
        let runtime = try SharedFixtures.json("contracts/lang-runtime-v1.json")
        let cases = try XCTUnwrap(runtime["cases"] as? [[String: Any]])
            .filter { ($0["name"] as? String)?.hasPrefix("text-cap-") == true }
        XCTAssertEqual(cases.count, 2)
        for c in cases {
            let input = try XCTUnwrap(c["input"] as? String)
            let actual = try XCTUnwrap(detector.detectText(input))
            XCTAssertEqual(actual, detector.detectText(utf16Units: Array(input.utf16)))
            try assertLanguageJSON(actual, equals: XCTUnwrap(c["expected"]), try XCTUnwrap(c["name"] as? String))
        }
    }

    func testExplicitUTF16AndConcurrentCallsAreDeterministic() throws {
        let fixture = try SharedFixtures.json("contracts/lang-score-v1.json")
        let detector = try LanguageDetector(testModelData: jsonBytes(XCTUnwrap(fixture["model"])), tables: UnicodeTables.bundled())
        XCTAssertEqual(detector.detectText(utf16Units: [55296, 55296, 56320, 65]), detector.detectText("\u{FFFD}\u{10000}A"))
        XCTAssertEqual(detector.detectDocument(utf16Units: [55296, 55296, 56320, 65]), detector.detectDocument("\u{FFFD}\u{10000}A"))
        let input = "aaaa aaaa aaaa bbbb bbbb bbbb aaaa aaaa aaaa"
        let text = try XCTUnwrap(detector.detectText(input))
        let document = try XCTUnwrap(detector.detectDocument(input))
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            XCTAssertEqual(detector.detectText(input), text)
            XCTAssertEqual(detector.detectDocument(input), document)
            XCTAssertEqual(detector.detectDocument(utf16Units: Array(input.utf16)), document)
        }
    }

    func testBundleAvailabilityTracksProductionResources() throws {
        if (try? LanguageDetector.bundledResourceData("lang-detector-v1.json")) != nil {
            XCTAssertTrue(LanguageDetector.bundled().isAvailable)
        } else {
            XCTAssertFalse(LanguageDetector.bundled().isAvailable)
        }
        XCTAssertThrowsError(try LanguageDetector.bundledResourceData("../NOTICE"))
    }

    private func loadingResources() throws -> [String: Data] {
        let fixture = try SharedFixtures.json("lang/loading-bundle-v1.json")
        XCTAssertEqual(fixture["testOnly"] as? Int, 1)
        var resources = try XCTUnwrap(fixture["resources"] as? [String: String]).mapValues {
            try XCTUnwrap(Data(base64Encoded: $0))
        }
        for name in try XCTUnwrap(fixture["sharedUnicodeResources"] as? [String]) {
            resources[name] = try LanguageDetector.bundledResourceData(name)
        }
        let model = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(resources["lang-detector-v1.json"])) as? [String: Any])
        XCTAssertEqual(model["modelId"] as? String, "wp4-loader-test-only")
        return resources
    }
    private func jsonBytes(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([10])
    }
    private func replacing(_ object: Any, at path: ArraySlice<String>, with replacement: Any) throws -> Any {
        guard let key = path.first else { return replacement }
        if var dictionary = object as? [String: Any] {
            if path.count == 1 { dictionary[key] = replacement }
            else { dictionary[key] = try replacing(XCTUnwrap(dictionary[key]), at: path.dropFirst(), with: replacement) }
            return dictionary
        }
        var array = try XCTUnwrap(object as? [Any])
        let index = try XCTUnwrap(Int(key))
        XCTAssertTrue(array.indices.contains(index))
        array[index] = try replacing(array[index], at: path.dropFirst(), with: replacement)
        return array
    }
}
