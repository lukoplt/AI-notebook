import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

/// Opt-in CPU benchmark (AINOTEBOOK_CPU_BENCH=1, contract `ingestion-memory-pressure-v1`
/// addendum A): the first scan (hashing) and the full extraction of a synthetic mixed
/// folder through the real scanner, job queue, admission, extractors and language
/// detector, at several worker counts. Reports wall time and process CPU time (CPU / wall
/// = average busy cores). The corpus comes from `tools/benchmark/gen_cpu_corpus.py`
/// (generated on first use) or from AINOTEBOOK_CPU_BENCH_DIR (any real folder).
///
/// Knobs: AINOTEBOOK_CPU_BENCH_WIDTHS (default "1,2,4,6,8"), AINOTEBOOK_CPU_BENCH_FILES
/// (generated corpus size, default 400), AINOTEBOOK_CPU_BENCH_BUDGET_MB (admission budget;
/// default 0 = the production budget for this machine), AINOTEBOOK_CPU_BENCH_HASH_WIDTH
/// (scanner hash width; default = the production width for the worker count).
@MainActor
final class ExtractionConcurrencyBenchmarkTests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    private func corpus() throws -> URL {
        if let dir = environment["AINOTEBOOK_CPU_BENCH_DIR"] { return URL(fileURLWithPath: dir, isDirectory: true) }
        let files = Int(environment["AINOTEBOOK_CPU_BENCH_FILES"] ?? "") ?? 400
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ainotebook-cpu-corpus-\(files)", isDirectory: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", root.appendingPathComponent("tools/benchmark/gen_cpu_corpus.py").path, out.path, "--files", "\(files)"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "corpus generator failed")
        return out
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    func testFolderExtractionConcurrency() async throws {
        guard environment["AINOTEBOOK_CPU_BENCH"] == "1" else {
            throw XCTSkip("set AINOTEBOOK_CPU_BENCH=1 to run the extraction concurrency benchmark")
        }
        let root = try corpus()
        let widths = (environment["AINOTEBOOK_CPU_BENCH_WIDTHS"] ?? "1,2,4,6,8").split(separator: ",").compactMap { Int($0) }
        let budgetMB = Int64(environment["AINOTEBOOK_CPU_BENCH_BUDGET_MB"] ?? "") ?? 0
        let budget = budgetMB > 0 ? budgetMB * 1_048_576
            : AdaptiveConcurrency.memoryBudget(physicalBytes: Int64(ProcessInfo.processInfo.physicalMemory))
        let fixedHashWidth = Int(environment["AINOTEBOOK_CPU_BENCH_HASH_WIDTH"] ?? "")
        let tables = try UnicodeTables.bundled()
        let fileSystem = NativeFolderFileSystem()
        let clock = SystemIngestLeaseClock()
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        print(String(format: "CPU-BENCH swift corpus=%@ cores=%d ram=%.0fGB budget=%dMB load1=%.2f", root.path,
                     ProcessInfo.processInfo.activeProcessorCount, Double(ProcessInfo.processInfo.physicalMemory) / 1e9,
                     budget / 1_048_576, load[0]))

        // Stage breakdown on one core: parse (extractor) vs detect + chunk (prepare); the rest
        // of a job is snapshot/verify IO and the serialized publication transaction.
        if environment["AINOTEBOOK_CPU_BENCH_STAGES"] != "0" {
            let extractor = BoundedDocumentExtractor(), detector = LanguageDetector.bundled()
            var parse: [String: Double] = [:], prepare: [String: Double] = [:], counts: [String: Int] = [:]
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
                .compactMap { $0 as? URL }.filter { SourceType.detect(filename: $0.lastPathComponent) != nil }
                .sorted { $0.path < $1.path }
            for url in files {
                let kind = SourceType.detect(filename: url.lastPathComponent)!
                let t0 = DispatchTime.now().uptimeNanoseconds
                guard let document = try? await extractor.extract(url: url, kind: kind, rules: .defaults) else { continue }
                let t1 = DispatchTime.now().uptimeNanoseconds
                _ = try FolderExtractionWorker.prepare(document: document, contentHash: "x", sizeBytes: 0, filename: url.lastPathComponent,
                                                       limits: .defaults, detector: detector)
                let t2 = DispatchTime.now().uptimeNanoseconds
                let ext = url.pathExtension.lowercased()
                parse[ext, default: 0] += Double(t1 - t0) / 1e9
                prepare[ext, default: 0] += Double(t2 - t1) / 1e9
                counts[ext, default: 0] += 1
            }
            for ext in counts.keys.sorted() {
                print(String(format: "CPU-BENCH swift stage %@ x%d: parse %.2fs (%.1f ms/file), detect+chunk %.2fs (%.1f ms/file)",
                             ext, counts[ext]!, parse[ext]!, parse[ext]! * 1000 / Double(counts[ext]!),
                             prepare[ext]!, prepare[ext]! * 1000 / Double(counts[ext]!)))
            }
        }

        for width in widths {
            let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("cpu-bench-\(UUID().uuidString).sqlite")
            defer { for suffix in ["", "-journal", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbURL.path + suffix) } }
            let store = try NotebookStore(path: StorePath(fileURL: dbURL), configuredEmbeddingModelKey: nil)
            let notebookId = try XCTUnwrap(store.createNotebook(name: "bench").id)
            let folder = try store.createFolder(notebookId: notebookId, draft: FolderDraft(rootPath: root.path, displayName: "Bench",
                includeExts: FolderRules.defaults.includeExts, ignoreGlobs: FolderRules.defaults.ignoreGlobs, limitsJSON: "{}",
                encodingFallback: "cp1250", watchEnabled: false), identity: fileSystem, now: clock.now())

            // First scan: every file is new, so every eligible file is hashed.
            let hashWidth = fixedHashWidth ?? AdaptiveConcurrency.hashWidth(extractionLimit: width)
            let scanJob = try store.requestFolderScan(folderId: folder.id, verifyAll: false, now: clock.now())
            XCTAssertNotNil(try store.claimJob(now: clock.now(), leaseToken: "scan", id: scanJob))
            let scanner = FolderScanner(store: store, fileSystem: fileSystem, tables: tables, clock: clock,
                                        hashWidth: { hashWidth })
            var cpu = Self.cpuSeconds(), start = DispatchTime.now().uptimeNanoseconds
            try await scanner.scan(folderId: folder.id, verifyAll: false, fence: JobFence(jobId: scanJob, leaseToken: "scan"),
                                   now: clock.now(), cancelled: { false })
            let scanWall = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9, scanCPU = Self.cpuSeconds() - cpu
            let queued = try store.runOnDatabase {
                try Int.fetchOne($0, sql: "SELECT count(*) FROM ingest_jobs WHERE kind='extract' AND state='queued'")!
            }

            // Full extraction: `width` dispatch loops over one admission, as the runtime runs them.
            let admission = IngestionAdmission(maxExtractions: width, memoryBytes: budget)
            let queue = JobQueue(store: store, clock: clock, admission: admission)
            let extractor = BoundedDocumentExtractor()
            let worker = FolderExtractionWorker(store: store, fileSystem: fileSystem, detector: .bundled(), clock: clock,
                embeddingSelection: { _ in nil },
                extract: { url, kind, rules in try await extractor.extract(url: url, kind: kind, rules: rules) })
            cpu = Self.cpuSeconds()
            start = DispatchTime.now().uptimeNanoseconds
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<width {
                    group.addTask(priority: .utility) {
                        while true {
                            let ran = try? await queue.runOne(kind: "extract", reservation: { job in
                                try await MainActor.run { try store.extractionReservation(job: job) }
                            }, execute: { job, fence in try await worker.execute(job: job, fence: fence) })
                            if ran != true { return }
                        }
                    }
                }
            }
            let wall = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9, used = Self.cpuSeconds() - cpu
            let (ready, failed, chunks) = try store.runOnDatabase { db in
                (try Int.fetchOne(db, sql: "SELECT count(*) FROM sources WHERE folder_id=? AND status='ready'", arguments: [folder.id])!,
                 try Int.fetchOne(db, sql: "SELECT count(*) FROM ingest_jobs WHERE kind='extract' AND state<>'done'")!,
                 try Int.fetchOne(db, sql: "SELECT count(*) FROM source_chunks")!)
            }
            print(String(format: "CPU-BENCH swift width=%d hashWidth=%d: scan %d files %.2fs wall %.2fs cpu (%.2f cores) | extract %d files (%d not done) %d chunks: %.2fs wall %.2fs cpu (%.2f cores busy) %.1f files/s",
                         width, hashWidth, queued, scanWall, scanCPU, scanCPU / max(scanWall, 1e-9), ready, failed, chunks,
                         wall, used, used / max(wall, 1e-9), Double(ready) / max(wall, 1e-9)))
            XCTAssertEqual(ready, queued, "width \(width): every queued file extracted")
        }
    }
}
