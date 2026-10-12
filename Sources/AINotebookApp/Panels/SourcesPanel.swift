import AINotebookCore
import AppKit
import SwiftUI

/// Sources segment of the right panel (spec §2.3): persisted folders as
/// collapsible trees with one summary line and a "…" menu, then loose
/// sources; "+" adds file/folder/URL/text; bulk mode and the tag filter live
/// in the panel "…" menu; files and folders can be dropped on the panel.
struct SourcesPanel: View {
    let notebook: Notebook

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var ingestion: IngestionServiceHolder
    @EnvironmentObject private var routerHolder: ProviderRouterHolder
    /// The process-wide runtime holder (folders, watches, durable ingestion).
    @EnvironmentObject private var folderWatch: FolderWatchController
    /// Shell-level indexing status of this notebook (strip, folder scan feedback).
    @EnvironmentObject private var indexing: IndexingStatusModel

    @State private var sources: [Source] = []
    @State private var addTab: AddSourceSheet.Tab?
    @State private var errorMessage: String?
    @State private var summaries: [Int64: String] = [:]
    @State private var summarizing: Set<Int64> = []
    @State private var isDropTarget = false
    @State private var previewSource: Source?
    @State private var allTags: [Tag] = []
    @State private var tagFilter: Int64?
    @State private var sourceTagIds: [Int64: Set<Int64>] = [:]
    @State private var bulkMode = false
    @State private var selectedIds: Set<Int64> = []
    /// Presentation-only folder rows; ingestion state lives in the runtime.
    @StateObject private var folders = FolderSourcesModel()
    @State private var rulesFolder: FolderSheetItem?
    @State private var removingFolder: FolderSheetItem?
    /// "N files couldn't be read" pressed: only the failing sources are listed.
    @State private var showingErrorsOnly = false
    @State private var errorSources: [Source] = []
    /// Sources whose extraction was given up after three failed attempts.
    @State private var gaveUp: Set<Int64> = []

    private var t: AppText { settings.text }

    /// Loose sources after applying the active tag filter (B8).
    private var displayedSources: [Source] { applyTagFilter(sources) }

    private func applyTagFilter(_ list: [Source]) -> [Source] {
        guard let tagFilter else { return list }
        return list.filter { source in
            guard let id = source.id else { return false }
            return sourceTagIds[id]?.contains(tagFilter) ?? false
        }
    }

    /// Loose sources, every loaded folder member and the listed failing sources (bulk actions span all).
    private var allLoadedSources: [Source] { sources + folders.loadedMembers + errorSources }

    private func makeSummarizer() -> SourceSummarizer {
        SourceSummarizer(store: store, chat: routerHolder.router, chatModel: settings.selectedChatModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
                .padding(.horizontal, DesignTokens.spacing(12))
                .padding(.vertical, DesignTokens.spacing(8))
            if bulkMode { bulkActionBar }
            Hairline()
            IndexingStatusStrip(showingErrorsOnly: $showingErrorsOnly)
            if sources.isEmpty && folders.rows.isEmpty {
                EmptyStateView(title: t.string(.noSourcesEmptyState), actions: [
                    EmptyStateAction(title: t.string(.addFolderButton), icon: .addFolder, isPrimary: true) { chooseFolder() },
                    EmptyStateAction(title: t.string(.composerAddFile), icon: .addFile) { addTab = .file },
                ], compact: true)
            } else {
                list
            }
            if let message = errorMessage ?? folders.errorKey.map({ t.string($0) }) {
                Label(message, systemImage: DesignTokens.icon(.warning))
                    .tokenFont(.caption)
                    .tokenForeground(.danger)
                    .lineLimit(3)
                    .padding(DesignTokens.spacing(12))
                    .onTapGesture { errorMessage = nil; folders.errorKey = nil }
            }
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: DesignTokens.radius(.md), style: .continuous)
                    .strokeBorder(DesignTokens.color(.focus),
                                  style: StrokeStyle(lineWidth: DesignTokens.size(.focusRing), dash: [6]))
                    .padding(DesignTokens.spacing(8))
            }
        }
        // B5 — drag & drop files and folders onto Sources.
        .dropDestination(for: URL.self) { urls, _ in
            ingestDropped(urls)
            return true
        } isTargeted: { isDropTarget = $0 }
        .task(id: notebook.id) {
            folders.configure(store: store, runtime: folderWatch.runtime)
            folders.onChange = { await reload() }
            folders.onMembersLoaded = { members in loadDetails(for: members) }
            await reload()
            if let id = notebook.id {
                await folders.reload(notebookId: id)
                folders.subscribe(notebookId: id)
            }
            #if DEBUG
            // Screenshot state: the first folder expanded.
            if UserDefaults.standard.string(forKey: "AINotebookQAScreen") == "sources",
               let first = folders.rows.first, !folders.isExpanded(first.id) {
                folders.toggle(folderId: first.id)
            }
            #endif
        }
        .onDisappear { folders.unsubscribe() }
        .onChange(of: showingErrorsOnly) { _, _ in loadErrorSources() }
        .sheet(item: $rulesFolder) { item in
            FolderRulesSheet(folder: item.folder, text: t,
                             validate: { await folders.validate(id: item.folder.id, rules: $0) },
                             onSave: { try await folders.applyRules(id: item.folder.id, rules: $0) })
        }
        .confirmationDialog(t.string(.folderRemoveConfirm), isPresented: Binding(
            get: { removingFolder != nil }, set: { if !$0 { removingFolder = nil } }
        ), presenting: removingFolder) { item in
            Button(t.string(.folderRemoveButton), role: .destructive) {
                Task { await folders.remove(id: item.folder.id); await reload() }
            }
            Button(t.string(.cancel), role: .cancel) {}
        } message: { _ in
            Text(t.string(.folderRemoveKeepsFiles))
        }
        .sheet(item: Binding(get: { addTab.map(AddTabItem.init) }, set: { addTab = $0?.tab }),
               onDismiss: { Task { await reload() } }) { item in
            AddSourceSheet(notebookId: notebook.id!, language: settings.language, ingestion: ingestion.service,
                           isPresented: Binding(get: { addTab != nil }, set: { if !$0 { addTab = nil } }),
                           initialTab: item.tab)
        }
        .sheet(item: $previewSource, onDismiss: { Task { await reload() } }) { source in
            SourcePreviewSheet(source: source, isPresented: Binding(
                get: { previewSource != nil },
                set: { if !$0 { previewSource = nil } }
            ))
            .environmentObject(settings)
            .environmentObject(store)
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: DesignTokens.spacing(4)) {
            if let tagFilter, let tag = allTags.first(where: { $0.id == tagFilter }) {
                ChipButton(tag.name, icon: .tag, isActive: true) { self.tagFilter = nil }
                    .help(t.string(.tagFilterAll))
            }
            Spacer(minLength: 0)
            IconMenu(icon: .add, label: t.string(.addSourceButton)) {
                Button { addTab = .file } label: {
                    Label(t.string(.composerAddFile), systemImage: DesignTokens.icon(.addFile))
                }
                Button { chooseFolder() } label: {
                    Label(t.string(.addFolderButton), systemImage: DesignTokens.icon(.addFolder))
                }
                Button { addTab = .url } label: {
                    Label(t.string(.composerAddUrl), systemImage: DesignTokens.icon(.addUrl))
                }
                Button { addTab = .text } label: {
                    Label(t.string(.sourcesAddText), systemImage: DesignTokens.icon(.addText))
                }
            }
            IconMenu(icon: .more, label: t.string(.shellMore)) {
                if !sources.isEmpty || !folders.rows.isEmpty {
                    Button {
                        bulkMode.toggle()
                        selectedIds.removeAll()
                    } label: {
                        Label(bulkMode ? t.string(.bulkDone) : t.string(.bulkSelect),
                              systemImage: DesignTokens.icon(.bulkSelect))
                    }
                }
                if !allTags.isEmpty {
                    Menu {
                        Button(t.string(.tagFilterAll)) { tagFilter = nil }
                        Divider()
                        ForEach(allTags) { tag in
                            Button { tagFilter = tag.id } label: {
                                if tagFilter == tag.id { Label(tag.name, systemImage: "checkmark") }
                                else { Text(tag.name) }
                            }
                        }
                    } label: {
                        Label(t.string(.tagFilterMenu), systemImage: DesignTokens.icon(.tag))
                    }
                }
            }
        }
        .frame(minHeight: DesignTokens.size(.hitMin))
    }

    private var bulkActionBar: some View {
        HStack(spacing: DesignTokens.spacing(8)) {
            Text("\(selectedIds.count)").tokenFont(.caption).monospacedDigit().tokenForeground(.text2)
            Spacer()
            Button(t.string(.bulkSummarize)) { Task { await bulkSummarize() } }
                .buttonStyle(.secondary)
                .disabled(selectedIds.isEmpty)
            Button(t.string(.bulkDelete), role: .destructive) { bulkDelete() }
                .buttonStyle(.secondary)
                .disabled(selectedIds.isEmpty)
            Button(t.string(.bulkDone)) { bulkMode = false; selectedIds.removeAll() }
                .buttonStyle(QuietButtonStyle(token: .focus))
        }
        .padding(.horizontal, DesignTokens.spacing(12))
        .padding(.bottom, DesignTokens.spacing(8))
    }

    // MARK: List

    private var list: some View {
        List {
            if showingErrorsOnly {
                // Every failing source of the notebook (loose and folder members), flat.
                ForEach(applyTagFilter(errorSources)) { source in
                    sourceItem(source)
                }
            } else {
                allSourceRows
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var allSourceRows: some View {
        // Persisted folders first; members are collapsed by default and paged in
        // lazily (List only renders visible rows), then the loose sources.
        ForEach(folders.rows) { row in
            folderRow(row)
            if let state = folders.expanded[row.id] {
                ForEach(applyTagFilter(state.members)) { source in
                    sourceItem(source).padding(.leading, DesignTokens.spacing(24))
                }
                folderMembersFooter(row.id, state)
            }
        }
        ForEach(displayedSources) { source in
            sourceItem(source)
        }
    }

    /// Folder row: chevron, icon, name, one summary line; the full coverage
    /// (corpus, freshness and availability counts, never summed) and last scan
    /// are in the tooltip and the "…" menu holds the commands.
    private func folderRow(_ row: FolderRow) -> some View {
        let folder = row.folder
        let isExpanded = folders.isExpanded(folder.id)
        return HStack(alignment: .top, spacing: DesignTokens.spacing(8)) {
            Button {
                // Hidden members never stay selected for a bulk action.
                if let state = folders.expanded[folder.id] { selectedIds.subtract(state.members.compactMap(\.id)) }
                folders.toggle(folderId: folder.id)
            } label: {
                HStack(alignment: .top, spacing: DesignTokens.spacing(8)) {
                    Image(systemName: DesignTokens.icon(isExpanded ? .chevronDown : .chevronRight))
                        .font(DesignTokens.font(.caption))
                        .tokenForeground(.text3)
                        .frame(width: DesignTokens.size(.iconRow) - 4, height: DesignTokens.lineHeight(.body))
                    TokenIcon(icon: .folder)
                        .frame(height: DesignTokens.lineHeight(.body))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.draft.displayName)
                            .tokenFont(.body)
                            .fontWeight(.medium)
                            .tokenForeground(.text1)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        folderStatusLine(row)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(detailTooltip(row))
            .accessibilityLabel("\(folder.draft.displayName), \(summaryLine(row))")
            .accessibilityHint(t.string(isExpanded ? .folderHideFiles : .folderShowFiles))
            if folder.draft.watchEnabled {
                TokenIcon(icon: .watch, color: .text3)
                    .frame(height: DesignTokens.lineHeight(.body))
                    .help(t.string(.folderWatchEnabled))
                    .accessibilityLabel(t.string(.folderWatchEnabled))
            }
            IconMenu(icon: .more, label: t.string(.shellMore)) {
                Button { Task { await indexing.scan(folderId: folder.id, verifyAll: false, folders: folders) } } label: {
                    Label(t.string(.folderScanNow), systemImage: DesignTokens.icon(.scan))
                }
                Button { Task { await indexing.scan(folderId: folder.id, verifyAll: true, folders: folders) } } label: {
                    Label(t.string(.folderVerifyAll), systemImage: DesignTokens.icon(.verify))
                }
                Button { rulesFolder = FolderSheetItem(folder: folder) } label: {
                    Label(t.string(.folderRulesTitle) + "…", systemImage: DesignTokens.icon(.rules))
                }
                Toggle(isOn: Binding(
                    get: { folder.draft.watchEnabled },
                    set: { enabled in Task { await folders.setWatching(id: folder.id, enabled: enabled) } }
                )) {
                    Label(t.string(.folderWatchEnabled), systemImage: DesignTokens.icon(.watch))
                }
                Divider()
                Button(role: .destructive) { removingFolder = FolderSheetItem(folder: folder) } label: {
                    Label(t.string(.folderRemoveButton), systemImage: DesignTokens.icon(.delete))
                }
            }
        }
        .padding(.vertical, DesignTokens.spacing(4))
        .listRowSeparator(.hidden)
    }

    /// Second line of a folder row: "Checking folder…" with a spinner right after
    /// Scan now / Verify all and while the folder scans, then the scan outcome for
    /// a few seconds, otherwise the summary; a scan warning is spelled out below.
    @ViewBuilder
    private func folderStatusLine(_ row: FolderRow) -> some View {
        let folder = row.folder
        if indexing.isChecking(folderId: folder.id) {
            HStack(spacing: DesignTokens.spacing(4)) {
                ProgressView().controlSize(.mini)
                Text(t.string(.folderChecking))
            }
            .tokenFont(.caption)
            .tokenForeground(.text2)
        } else if let outcome = indexing.tracker.caption(folder.id) {
            Text(IndexingStatusPresentation.scanOutcomeText(outcome, text: t))
                .tokenFont(.caption)
                .tokenForeground(.text2)
                .lineLimit(1)
        } else {
            Text(summaryLine(row))
                .tokenFont(.caption)
                .tokenForeground(row.coverage.refreshError > 0 || folder.lastScanError != nil ? .warning : .text3)
                .lineLimit(1)
        }
        if let warning = indexing.warning(folderId: folder.id) {
            Label(IndexingStatusPresentation.scanWarningText(warning, text: t, errorKey: { FolderSourcesModel.key(code: $0 ?? "") }),
                  systemImage: DesignTokens.icon(.warning))
                .tokenFont(.caption)
                .tokenForeground(.warning)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Files: 1204 · Errors: 3" (a lower bound is marked "≥").
    private func summaryLine(_ row: FolderRow) -> String {
        let c = row.coverage
        let inventory = c.searchable + c.notSearchable + c.skipped + c.missing + c.unavailable
        var parts = [String(format: t.string(.folderSummaryFiles), (c.isLowerBound ? "≥ " : "") + String(inventory))]
        let errors = c.refreshError + (row.folder.lastScanError == nil ? 0 : 1)
        if errors > 0 { parts.append(String(format: t.string(.folderSummaryErrors), errors)) }
        if c.refreshPending > 0 { parts.append("\(t.string(.folderRefreshPending)): \(c.refreshPending)") }
        return parts.joined(separator: " · ")
    }

    private func detailTooltip(_ row: FolderRow) -> String {
        let c = row.coverage, folder = row.folder
        var lines = [folder.draft.rootPath]
        lines.append("\(t.string(.folderSearchable)): \(c.searchable) · \(t.string(.folderNotSearchable)): \(c.notSearchable)")
        lines.append("\(t.string(.folderCurrent)): \(c.current) · \(t.string(.folderRefreshPending)): \(c.refreshPending) · \(t.string(.folderRefreshError)): \(c.refreshError)")
        lines.append("\(t.string(.folderSkipped)): \(c.skipped) · \(t.string(.folderMissing)): \(c.missing) · \(t.string(.folderUnavailable)): \(c.unavailable)")
        lines.append(lastScanText(folder))
        if let error = folder.lastScanError { lines.append(t.string(FolderSourcesModel.key(code: error))) }
        return lines.joined(separator: "\n")
    }

    /// Count of loaded vs. all members, the next-page button and the empty-folder note.
    private func folderMembersFooter(_ folderId: Int64, _ state: FolderMembersState) -> some View {
        HStack(spacing: DesignTokens.spacing(8)) {
            if state.isLoading { ProgressView().controlSize(.small) }
            Text(t.folderFilesCount(shown: state.members.count, total: state.total))
                .monospacedDigit()
                .tokenForeground(.text3)
            if state.hasMore {
                Button(t.string(.folderLoadMoreFiles)) { folders.loadMore(folderId: folderId) }
                    .buttonStyle(QuietButtonStyle(token: .focus))
            }
            if !state.isLoading && state.total == 0 {
                Text(t.string(.folderNoFiles)).tokenForeground(.text3)
            }
        }
        .tokenFont(.caption)
        .padding(.leading, DesignTokens.spacing(24) + DesignTokens.spacing(8))
        .listRowSeparator(.hidden)
    }

    private func lastScanText(_ folder: FolderSource) -> String {
        guard let at = folder.lastFullScanAt else { return t.string(.folderNeverScanned) }
        let locale = Locale(identifier: settings.language == .czech ? "cs_CZ" : "en_US")
        let date = Date(timeIntervalSince1970: TimeInterval(at)).formatted(.dateTime.locale(locale))
        return "\(t.string(.folderLastFullScan)): \(date)"
    }

    /// One source: bulk selection, preview on click, summary, re-crawl and delete.
    private func sourceItem(_ source: Source) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.spacing(8)) {
            if bulkMode, let id = source.id {
                Image(systemName: selectedIds.contains(id) ? "checkmark.circle.fill" : "circle")
                    .tokenForeground(selectedIds.contains(id) ? .text1 : .text3)
                    .frame(height: DesignTokens.lineHeight(.body))
                    .accessibilityHidden(true)
            }
            TokenIcon(icon: source.type == .web ? .addUrl : .file)
                .frame(height: DesignTokens.lineHeight(.body))
            VStack(alignment: .leading, spacing: 2) {
                // A folder member is identified by its path inside the folder.
                Text(source.folderId != nil ? (source.relPath ?? source.title) : source.title)
                    .tokenFont(.body)
                    .tokenForeground(.text1)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(source.title)
                HStack(spacing: DesignTokens.spacing(4)) {
                    Text(statusText(source.status))
                        .tokenForeground(source.status == .error ? .danger : .text3)
                    if source.status == .error, let detail = IngestionErrorText.key(for: source.error).map(t.string) {
                        Text("· " + detail)
                            .tokenForeground(.danger)
                            .help(detail)
                    }
                    if source.status == .error, let id = source.id, gaveUp.contains(id) {
                        Text("· " + t.string(.sourceGaveUp)).tokenForeground(.danger)
                    }
                    if source.availability == "missing" || source.availability == "unavailable" {
                        Text("· " + t.string(source.availability == "missing" ? .folderMissing : .folderUnavailable))
                            .tokenForeground(.warning)
                    }
                    if let language = t.languageBadge(source.lang) {
                        Text("· \(language)")
                            .tokenForeground(.text3)
                            .help(t.string(.sourceLanguageLabel))
                            .accessibilityLabel("\(t.string(.sourceLanguageLabel)): \(language)")
                    }
                    // UTF-8 is the norm; only a fallback encoding is worth showing.
                    if let encoding = source.encoding, encoding.lowercased() != "utf-8" {
                        Text("· \(t.string(.folderEncodingUsed)): \(encoding)").tokenForeground(.text3)
                    }
                    if let id = source.id, summarizing.contains(id) {
                        ProgressView().controlSize(.mini)
                        Text(t.string(.sourceSummarizingStatus)).tokenForeground(.text3)
                    }
                }
                .tokenFont(.caption)
                .lineLimit(1)
                if canRetry(source), let id = source.id, !bulkMode {
                    Button { retry(id) } label: { Text(t.string(.sourceRetryButton)).tokenFont(.caption) }
                        .buttonStyle(.secondary)
                        .fixedSize()
                }
                if let id = source.id, let summary = summaries[id], !summary.isEmpty {
                    Text(summary)
                        .tokenFont(.caption)
                        .tokenForeground(.text2)
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .help(summary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DesignTokens.spacing(4))
        .contentShape(Rectangle())
        .onTapGesture {
            if bulkMode, let id = source.id {
                if selectedIds.contains(id) { selectedIds.remove(id) } else { selectedIds.insert(id) }
            } else {
                previewSource = source
            }
        }
        .contextMenu {
            Button(t.string(.sourcePreviewTitle)) { previewSource = source }
            if let id = source.id, summaries[id] == nil, source.status == .ready, !summarizing.contains(id) {
                Button(t.string(.sourceSummarizeButton)) { Task { await summarize(source) } }
            }
            if source.type == .web || (source.rawPath != nil && source.folderId == nil) {
                Button(t.string(.recrawlSourceButton)) { recrawl(source) }
            }
            if canRetry(source), let id = source.id {
                Button(t.string(.sourceRetryButton)) { retry(id) }
            }
            Divider()
            Button(t.string(.deleteButton), role: .destructive) { delete(source) }
        }
        .listRowSeparator(.hidden)
    }

    private func statusText(_ status: SourceStatus) -> String {
        switch status {
        case .pending:  return t.string(.sourceStatusPending)
        case .chunking: return t.string(.sourceStatusChunking)
        case .ready:    return t.string(.sourceStatusReady)
        case .error:    return t.string(.sourceStatusError)
        }
    }

    // MARK: Loading

    /// Loose sources only: folder members are paged per expanded folder by `FolderSourcesModel`,
    /// so a folder with thousands of files never loads (or queries summaries) in full.
    private func reload() async {
        do {
            sources = try store.looseSources(notebookId: notebook.id!)
            summaries = [:]
            sourceTagIds = [:]
            loadDetails(for: allLoadedSources)
            allTags = try store.tags()
            if let f = tagFilter, !allTags.contains(where: { $0.id == f }) { tagFilter = nil }
            loadErrorSources()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// A failed folder member or loose file/URL can be retried (`ingestion-retry-cap-v1` §5).
    private func canRetry(_ source: Source) -> Bool {
        source.status == .error && source.type != .note
            && (source.folderId != nil || source.rawPath != nil || source.uri != nil)
    }

    /// "Retry" on a failed source, folder member or loose (`ingestion-retry-cap-v1` §5).
    private func retry(_ sourceId: Int64) {
        Task {
            await folders.retry(sourceId: sourceId)
            await reloadAll()
        }
    }

    /// The notebook's failing sources for the "N files couldn't be read" filter.
    private func loadErrorSources() {
        gaveUp = notebook.id.flatMap { try? store.gaveUpSourceIds(notebookId: $0) } ?? []
        guard showingErrorsOnly, let id = notebook.id else { errorSources = []; return }
        do {
            errorSources = try store.sources(notebookId: id).filter { $0.status == .error }
            loadDetails(for: errorSources)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Sources list and folder rows (coverage and expanded members) together.
    private func reloadAll() async {
        await reload()
        if let id = notebook.id { await folders.reload(notebookId: id) }
    }

    /// Persisted summaries and tag ids for the given (visible) sources.
    private func loadDetails(for list: [Source]) {
        do {
            for source in list {
                guard let id = source.id else { continue }
                if let summary = try store.sourceSummary(id: id), !summary.isEmpty { summaries[id] = summary }
                else { summaries[id] = nil }
                sourceTagIds[id] = Set(try store.tagsForSource(sourceId: id).map(\.id))
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    // MARK: Actions

    /// B6 / W-2 — summarize every selected source.
    @MainActor
    private func bulkSummarize() async {
        let summarizer = makeSummarizer()
        for id in selectedIds {
            guard let source = allLoadedSources.first(where: { $0.id == id }), source.status == .ready else { continue }
            summarizing.insert(id)
            do {
                let summary = try await summarizer.summarize(sourceId: id)
                if !summary.isEmpty { summaries[id] = summary }
            } catch { errorMessage = String(describing: error) }
            summarizing.remove(id)
        }
    }

    /// B6 — delete every selected source.
    private func bulkDelete() {
        do {
            // Database rows only: a folder member's file on disk is never touched.
            for id in selectedIds { try store.deleteSource(id: id) }
            selectedIds.removeAll()
            bulkMode = false
            Task { await reloadAll() }
        } catch { errorMessage = String(describing: error) }
    }

    @MainActor
    private func summarize(_ source: Source) async {
        guard let id = source.id, !summarizing.contains(id) else { return }
        summarizing.insert(id)
        defer { summarizing.remove(id) }
        do {
            let summary = try await makeSummarizer().summarize(sourceId: id)
            if !summary.isEmpty { summaries[id] = summary }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func chooseFolder() {
        guard let folder = NotebookActions.chooseFolder(), let notebookId = notebook.id else { return }
        Task {
            await folders.add(url: folder, notebookId: notebookId)
            await reload()
        }
    }

    /// B5 — ingest dropped items, then refresh. Directories become persisted
    /// folders (the runtime resolves root aliases); files are ingested; non-file
    /// URLs go to the URL ingester. A failed item never discards its siblings.
    private func ingestDropped(_ urls: [URL]) {
        guard let notebookId = notebook.id else { return }
        Task {
            for url in urls {
                do {
                    if url.isFileURL {
                        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                        if isDirectory {
                            await folders.add(url: url, notebookId: notebookId)
                        } else {
                            _ = try await ingestion.service.ingestFile(url, into: notebookId)
                        }
                    } else {
                        _ = try await ingestion.service.ingestURL(url, into: notebookId)
                    }
                } catch {
                    errorMessage = String(describing: error)
                }
            }
            await reload()
            await folders.reload(notebookId: notebookId)
        }
    }

    /// E2 — re-crawl a single web/file source.
    private func recrawl(_ source: Source) {
        guard let id = source.id else { return }
        Task {
            do {
                try await LiveSourceSync(store: store, ingestion: ingestion.service).recrawl(sourceId: id)
                await reload()
            } catch { errorMessage = String(describing: error) }
        }
    }

    private func delete(_ source: Source) {
        do {
            // Database rows only: a folder member's file on disk is never touched.
            try store.deleteSource(id: source.id!)
            Task { await reloadAll() }
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

/// Sheet/dialog identity for one persisted folder.
struct FolderSheetItem: Identifiable {
    let folder: FolderSource
    var id: Int64 { folder.id }
}

/// Sheet identity for "Add source" opened on a given tab.
private struct AddTabItem: Identifiable {
    let tab: AddSourceSheet.Tab
    var id: String { String(describing: tab) }
}
