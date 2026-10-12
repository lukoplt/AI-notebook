#if DEBUG
import AINotebookCore
import AppKit
import SwiftUI

/// Debug-only: `-AINotebookRenderIndexingStrips <dir>` renders the Sources
/// status strip for every QA phase (`IndexingStatusModel.qaPhases`), light and
/// dark, to `<dir>/indexing-<phase>-<light|dark>.png` and exits before the
/// app opens its store or touches any preference. Live states are reachable
/// in the running app with `-AINotebookQAIndexing <phase>`.
@MainActor
enum IndexingStripRenderer {
    static let argument = "AINotebookRenderIndexingStrips"

    static func runIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: argument) else { return }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try render(to: dir, language: UserDefaults.standard.string(forKey: "AINotebookRenderLanguage") == "cs" ? .czech : .english)
            exit(0)
        } catch {
            FileHandle.standardError.write("IndexingStripRenderer failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    private static func render(to dir: URL, language: AppLanguage) throws {
        let text = AppText(language: language)
        for name in IndexingStatusModel.qaPhases {
            guard let status = IndexingStatusModel.qaStatus(named: name),
                  let presentation = IndexingStatusPresentation.make(
                      status, searchableFiles: IndexingStatusModel.qaSearchableFiles, text: text) else { continue }
            for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let view = IndexingStatusStripView(
                    presentation: presentation,
                    actionTitle: presentation.action.map { IndexingStatusPresentation.title($0, text: text) }
                )
                .frame(width: DesignTokens.size(.panelMin) + DesignTokens.spacing(32))
                .padding(.vertical, DesignTokens.spacing(4))
                .background(DesignTokens.color(.surface1))
                .environment(\.colorScheme, scheme == "dark" ? .dark : .light)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                var data: Data?
                NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                    guard let image = renderer.cgImage else { return }
                    data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                }
                guard let data else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: dir.appendingPathComponent("indexing-\(name)-\(scheme).png"))
            }
        }
    }
}
#endif
