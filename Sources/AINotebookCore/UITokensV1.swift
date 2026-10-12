import Foundation

/// Design tokens v1 — values of the shared contract
/// `Tests/fixtures/contracts/ui-tokens-v1.json` (human table: docs/design/tokens-v1.md).
/// `DesignTokens` in the app maps these to SwiftUI; `UITokensTests` keeps them
/// equal to the fixture. Never edit a value here without a new contract version.
public enum UITokensV1 {
    public struct ColorPair: Equatable, Sendable {
        public let light: String
        public let dark: String

        public init(light: String, dark: String) {
            self.light = light
            self.dark = dark
        }
    }

    public enum ColorToken: String, CaseIterable, Sendable {
        case bg
        case bgSidebar = "bg-sidebar"
        case surface1 = "surface-1"
        case surface2 = "surface-2"
        case border
        case text1 = "text-1"
        case text2 = "text-2"
        case text3 = "text-3"
        case accent
        case onAccent = "on-accent"
        case focus
        case success
        case warning
        case danger
    }

    public static func color(_ token: ColorToken) -> ColorPair {
        switch token {
        case .bg: return ColorPair(light: "#FFFFFF", dark: "#1E1E1E")
        case .bgSidebar: return ColorPair(light: "#F7F7F8", dark: "#181818")
        case .surface1: return ColorPair(light: "#FFFFFF", dark: "#252525")
        case .surface2: return ColorPair(light: "#F2F2F3", dark: "#2E2E2E")
        case .border: return ColorPair(light: "#E5E5E7", dark: "#3A3A3A")
        case .text1: return ColorPair(light: "#0D0D0D", dark: "#ECECEC")
        case .text2: return ColorPair(light: "#5D5D63", dark: "#A7A7AD")
        case .text3: return ColorPair(light: "#8E8E93", dark: "#6E6E73")
        case .accent: return ColorPair(light: "#0D0D0D", dark: "#ECECEC")
        case .onAccent: return ColorPair(light: "#FFFFFF", dark: "#0D0D0D")
        case .focus: return ColorPair(light: "#2F6FEB", dark: "#4C8DFF")
        case .success: return ColorPair(light: "#1F8A4C", dark: "#3FB96E")
        case .warning: return ColorPair(light: "#B26A00", dark: "#E0A33A")
        case .danger: return ColorPair(light: "#C42B1C", dark: "#FF6B5E")
        }
    }

    /// `#RRGGBB` → components in 0…1; nil for anything else.
    public static func components(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        let scalars = Array(hex.unicodeScalars)
        guard scalars.count == 7, scalars[0] == "#",
              let value = UInt32(String(hex.dropFirst()), radix: 16),
              scalars.dropFirst().allSatisfy({ $0.properties.isASCIIHexDigit }) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255.0,
                Double((value >> 8) & 0xFF) / 255.0,
                Double(value & 0xFF) / 255.0)
    }

    public enum Weight: String, Sendable {
        case regular
        case semibold
    }

    public struct TypeSpec: Equatable, Sendable {
        public let size: Int
        public let line: Int
        /// Line height on Windows (differs only for `body`).
        public let lineWindows: Int
        public let weight: Weight
    }

    public enum TypeStyle: String, CaseIterable, Sendable {
        case title
        case headline
        case body
        case message
        case caption
        case mono
    }

    public static func type(_ style: TypeStyle) -> TypeSpec {
        switch style {
        case .title: return TypeSpec(size: 20, line: 28, lineWindows: 28, weight: .semibold)
        case .headline: return TypeSpec(size: 15, line: 22, lineWindows: 22, weight: .semibold)
        case .body: return TypeSpec(size: 14, line: 22, lineWindows: 20, weight: .regular)
        case .message: return TypeSpec(size: 15, line: 24, lineWindows: 24, weight: .regular)
        case .caption: return TypeSpec(size: 12, line: 16, lineWindows: 16, weight: .regular)
        case .mono: return TypeSpec(size: 13, line: 20, lineWindows: 20, weight: .regular)
        }
    }

    /// System fonts only (the app uses `.system`; names are informative).
    public static let fontText = "SF Pro"
    public static let fontMono = "SF Mono"

    /// 4 pt grid.
    public static let spacing: [Int] = [4, 8, 12, 16, 24, 32]

    public enum Radius: String, CaseIterable, Sendable {
        case sm
        case md
        case lg
        case pill
    }

    public static func radius(_ radius: Radius) -> Int {
        switch radius {
        case .sm: return 6
        case .md: return 10
        case .lg: return 16
        case .pill: return 999
        }
    }

    public enum Size: String, CaseIterable, Sendable {
        case sidebarRow
        case topBar
        case hitMin
        case primaryHitMin
        case conversationMax
        case sidebarMin
        case sidebarMax
        case panelMin
        case panelMax
        case iconRow
        case iconTopBar
        case userMessagePadV
        case userMessagePadH
        case userMessageMaxPercent
        case composerMinLines
        case composerMaxLines
        case settingsContentMax
        case onboardingCardMax
        case focusRing
        case borderWidth
        case sidebarChatsVisible
    }

    public static func size(_ size: Size) -> Int {
        switch size {
        case .sidebarRow: return 30
        case .topBar: return 44
        case .hitMin: return 28
        case .primaryHitMin: return 32
        case .conversationMax: return 760
        case .sidebarMin: return 240
        case .sidebarMax: return 300
        case .panelMin: return 320
        case .panelMax: return 420
        case .iconRow: return 16
        case .iconTopBar: return 18
        case .userMessagePadV: return 10
        case .userMessagePadH: return 14
        case .userMessageMaxPercent: return 80
        case .composerMinLines: return 1
        case .composerMaxLines: return 8
        case .settingsContentMax: return 640
        case .onboardingCardMax: return 520
        case .focusRing: return 2
        case .borderWidth: return 1
        case .sidebarChatsVisible: return 8
        }
    }

    public enum Motion: String, CaseIterable, Sendable {
        case fastMs
        case slowMs
    }

    public static func milliseconds(_ motion: Motion) -> Int {
        switch motion {
        case .fastMs: return 120
        case .slowMs: return 180
        }
    }

    public struct IconSpec: Equatable, Sendable {
        public let sfSymbol: String
        /// Segoe Fluent Icons code point, hex (e.g. "E70F").
        public let fluentGlyph: String

        public init(sfSymbol: String, fluentGlyph: String) {
            self.sfSymbol = sfSymbol
            self.fluentGlyph = fluentGlyph
        }
    }

    public enum Icon: String, CaseIterable, Sendable {
        case newChat
        case search
        case settings
        case notebook
        case chat
        case chevronDown
        case chevronRight
        case back
        case add
        case more
        case togglePanel
        case updateDot
        case send
        case stop
        case previewContext
        case scope
        case persona
        case model
        case copy
        case regenerate
        case saveAsNote
        case sentContext
        case edit
        case warning
        case addFile
        case addFolder
        case addUrl
        case addText
        case webSearch
        case overview
        case runTool
        case note
        case folder
        case file
        case scan
        case verify
        case rules
        case watch
        case delete
        case tag
        case bulkSelect
        case history
        case export
        case instructions
        case backup
        case restore
        case openOriginal
        case citation
        case info
        case error
        case success
        case close
        case providers
        case modelsLimits
        case indexing
    }

    public static func icon(_ icon: Icon) -> IconSpec {
        switch icon {
        case .newChat: return IconSpec(sfSymbol: "square.and.pencil", fluentGlyph: "E70F")
        case .search: return IconSpec(sfSymbol: "magnifyingglass", fluentGlyph: "E721")
        case .settings: return IconSpec(sfSymbol: "gearshape", fluentGlyph: "E713")
        case .notebook: return IconSpec(sfSymbol: "book.closed", fluentGlyph: "E8F1")
        case .chat: return IconSpec(sfSymbol: "bubble.left", fluentGlyph: "E8BD")
        case .chevronDown: return IconSpec(sfSymbol: "chevron.down", fluentGlyph: "E70D")
        case .chevronRight: return IconSpec(sfSymbol: "chevron.right", fluentGlyph: "E76C")
        case .back: return IconSpec(sfSymbol: "chevron.left", fluentGlyph: "E72B")
        case .add: return IconSpec(sfSymbol: "plus", fluentGlyph: "E710")
        case .more: return IconSpec(sfSymbol: "ellipsis", fluentGlyph: "E712")
        case .togglePanel: return IconSpec(sfSymbol: "sidebar.right", fluentGlyph: "E8A0")
        case .updateDot: return IconSpec(sfSymbol: "circle.fill", fluentGlyph: "EA3B")
        case .send: return IconSpec(sfSymbol: "arrow.up", fluentGlyph: "E74A")
        case .stop: return IconSpec(sfSymbol: "stop.fill", fluentGlyph: "E71A")
        case .previewContext: return IconSpec(sfSymbol: "eye", fluentGlyph: "E890")
        case .scope: return IconSpec(sfSymbol: "scope", fluentGlyph: "E8B7")
        case .persona: return IconSpec(sfSymbol: "theatermasks", fluentGlyph: "E77B")
        case .model: return IconSpec(sfSymbol: "cpu", fluentGlyph: "E950")
        case .copy: return IconSpec(sfSymbol: "doc.on.doc", fluentGlyph: "E8C8")
        case .regenerate: return IconSpec(sfSymbol: "arrow.clockwise", fluentGlyph: "E72C")
        case .saveAsNote: return IconSpec(sfSymbol: "square.and.arrow.down", fluentGlyph: "E74E")
        case .sentContext: return IconSpec(sfSymbol: "doc.text.magnifyingglass", fluentGlyph: "E8A5")
        case .edit: return IconSpec(sfSymbol: "pencil", fluentGlyph: "E70F")
        case .warning: return IconSpec(sfSymbol: "exclamationmark.triangle", fluentGlyph: "E7BA")
        case .addFile: return IconSpec(sfSymbol: "doc.badge.plus", fluentGlyph: "E8E5")
        case .addFolder: return IconSpec(sfSymbol: "folder.badge.plus", fluentGlyph: "E8F4")
        case .addUrl: return IconSpec(sfSymbol: "link", fluentGlyph: "E71B")
        case .addText: return IconSpec(sfSymbol: "text.alignleft", fluentGlyph: "E8E4")
        case .webSearch: return IconSpec(sfSymbol: "globe", fluentGlyph: "E774")
        case .overview: return IconSpec(sfSymbol: "list.bullet.rectangle", fluentGlyph: "E8FD")
        case .runTool: return IconSpec(sfSymbol: "wand.and.stars", fluentGlyph: "E945")
        case .note: return IconSpec(sfSymbol: "note.text", fluentGlyph: "E7C3")
        case .folder: return IconSpec(sfSymbol: "folder", fluentGlyph: "E8B7")
        case .file: return IconSpec(sfSymbol: "doc", fluentGlyph: "E8A5")
        case .scan: return IconSpec(sfSymbol: "arrow.triangle.2.circlepath", fluentGlyph: "E895")
        case .verify: return IconSpec(sfSymbol: "checkmark.seal", fluentGlyph: "E73E")
        case .rules: return IconSpec(sfSymbol: "line.3.horizontal.decrease.circle", fluentGlyph: "E71C")
        case .watch: return IconSpec(sfSymbol: "binoculars", fluentGlyph: "E7B3")
        case .delete: return IconSpec(sfSymbol: "trash", fluentGlyph: "E74D")
        case .tag: return IconSpec(sfSymbol: "tag", fluentGlyph: "E8EC")
        case .bulkSelect: return IconSpec(sfSymbol: "checklist", fluentGlyph: "E762")
        case .history: return IconSpec(sfSymbol: "clock.arrow.circlepath", fluentGlyph: "E81C")
        case .export: return IconSpec(sfSymbol: "square.and.arrow.up", fluentGlyph: "EDE1")
        case .instructions: return IconSpec(sfSymbol: "text.badge.star", fluentGlyph: "E734")
        case .backup: return IconSpec(sfSymbol: "archivebox", fluentGlyph: "E896")
        case .restore: return IconSpec(sfSymbol: "arrow.uturn.backward", fluentGlyph: "E7A7")
        case .openOriginal: return IconSpec(sfSymbol: "arrow.up.forward.square", fluentGlyph: "E8A7")
        case .citation: return IconSpec(sfSymbol: "quote.opening", fluentGlyph: "E9D2")
        case .info: return IconSpec(sfSymbol: "info.circle", fluentGlyph: "E946")
        case .error: return IconSpec(sfSymbol: "xmark.octagon", fluentGlyph: "E783")
        case .success: return IconSpec(sfSymbol: "checkmark.circle", fluentGlyph: "E73E")
        case .close: return IconSpec(sfSymbol: "xmark", fluentGlyph: "E711")
        case .providers: return IconSpec(sfSymbol: "cloud", fluentGlyph: "E753")
        case .modelsLimits: return IconSpec(sfSymbol: "slider.horizontal.3", fluentGlyph: "E9E9")
        case .indexing: return IconSpec(sfSymbol: "square.stack.3d.up", fluentGlyph: "E81E")
        }
    }
}
