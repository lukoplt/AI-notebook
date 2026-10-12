import Foundation

/// Reads worksheet relationships and scalar-bounded values without evaluating
/// formulas, and renders the compact spreadsheet canonical text v2
/// (`ingestion-xlsx-v2`, `text_format_version` 2; same as Windows `XlsxReader`).
enum XlsxReader {
    private static let mainNamespaces: Set<String> = [
        "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
        "http://purl.oclc.org/ooxml/spreadsheetml/main"
    ]
    private static let relationshipNamespaces = [
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
        "http://purl.oclc.org/ooxml/officeDocument/relationships"
    ]

    private struct Sheet {
        let name: String
        let relationshipId: String
        var cells: [Cell] = []
    }

    private struct Cell {
        let reference: String
        let row: Int
        let column: Int
        let type: String
        let style: Int?
        var formula = false
        var valueSeen = false
        var inlineSeen = false
        var value = ""
        var inline = ""
        var sharedIndex: Int?
    }

    static func read(_ archive: BoundedOfficeReader) throws -> CanonicalDocument {
        let workbook = try archive.officeDocumentPart(conventional: "xl/workbook.xml")
        let relationships = try archive.relationships(for: workbook)
        var (sheets, date1904) = try readSheets(archive, path: workbook, relationships: relationships)
        var materialized = 0
        var rawScalars = 0
        var usedStrings = Set<Int>()
        var usedStyles = Set<Int>()
        var explicitStyles = false

        for index in sheets.indices {
            try Task.checkCancellation()
            guard let relation = relationships[sheets[index].relationshipId],
                  isRelationship(relation.type, kind: "worksheet") else {
                throw IngestionError(code: "invalidRelationship")
            }
            let cells = try readCells(archive, path: relation.target, materialized: &materialized,
                                      rawScalars: &rawScalars)
            for cell in cells {
                if let index = cell.sharedIndex { usedStrings.insert(index) }
                // Only numeric values can render as dates; a missing `s` is style 0.
                if cell.type == "n", !cell.value.isEmpty { usedStyles.insert(cell.style ?? 0) }
                explicitStyles = explicitStyles || cell.style != nil
            }
            sheets[index].cells = cells
        }

        let strings: [Int: String]
        if usedStrings.isEmpty { strings = [:] }
        else {
            // Some writers omit the sharedStrings relationship; use the conventional sibling part.
            let fallback = (workbook.split(separator: "/").dropLast().map(String.init) + ["sharedStrings.xml"])
                .joined(separator: "/")
            let path = try requiredPart(relationships, kind: "sharedStrings",
                                        fallback: archive.resolvePart(fallback))
            strings = try readSharedStrings(archive, path: path, requested: usedStrings)
        }
        let dateStyles: Set<Int>
        let hasStyles = relationships.values.contains { isRelationship($0.type, kind: "styles") }
        if usedStyles.isEmpty || (!hasStyles && !explicitStyles) { dateStyles = [] }
        else {
            let path = try requiredPart(relationships, kind: "styles")
            dateStyles = try readStyles(archive, path: path, requested: usedStyles)
        }

        var output = try CanonicalTextBuilder(maxScalars: archive.limits.textScalars)
        for (index, sheet) in sheets.enumerated() {
            if index > 0 { try output.append("\n\n") }
            try output.append("## ")
            try output.append(sheet.name)
            try output.append("\n")
            var rendered: [SpreadsheetText.RenderedCell] = []
            for cell in sheet.cells.sorted(by: { ($0.row, $0.column) < ($1.row, $1.column) }) {
                try Task.checkCancellation()
                let value = try render(cell, strings: strings, dateStyles: dateStyles, date1904: date1904)
                guard !value.isEmpty else { continue }
                rendered.append(SpreadsheetText.RenderedCell(row: cell.row, column: cell.column, text: value))
            }
            try SpreadsheetText.appendRows(rendered, to: &output)
        }
        return CanonicalDocument(text: output.text, title: nil, kind: "xlsx", pages: [],
                                 sheetNames: sheets.map(\.name), encoding: nil)
    }

    /// Chart, dialog and macro sheets carry no cell text and are skipped.
    private static let nonWorksheetKinds = ["chartsheet", "dialogsheet", "macrosheet"]

    /// Hidden and very hidden sheets are not user-visible content and are skipped like chart sheets.
    private static let hiddenStates: Set<String> = ["hidden", "veryHidden"]

    /// Visible worksheets in workbook order, and whether the workbook uses the 1904 date system.
    private static func readSheets(_ archive: BoundedOfficeReader, path: String,
                                   relationships: [String: OfficeRelationship]) throws -> ([Sheet], Bool) {
        var stack: [String] = []
        var sheets: [Sheet] = []
        var date1904 = false
        var ids = Set<String>()
        var names = Set<Data>()
        var nameScalars = 0
        var hasRoot = false
        try archive.parse(path, onStart: { element in
            let name = role(element)
            if stack.isEmpty {
                guard name == "workbook" else { throw IngestionError(code: "corruptArchive") }
                hasRoot = true
            }
            if name == "sheet", stack == ["workbook", "sheets"] {
                guard let title = element.attributes["name"], !title.isEmpty,
                      let relation = relationshipNamespaces.compactMap({ element.attribute("id", namespaceURI: $0) }).first,
                      !relation.isEmpty, ids.insert(relation).inserted else {
                    throw IngestionError(code: "invalidRelationship")
                }
                if let type = relationships[relation]?.type,
                   nonWorksheetKinds.contains(where: { isRelationship(type, kind: $0) }) {
                    stack.append(name)
                    return
                }
                if let state = element.attributes["state"], hiddenStates.contains(state) {
                    stack.append(name)
                    return
                }
                try consume(title, total: &nameScalars, limit: archive.limits.textScalars)
                guard names.insert(Data(title.utf8)).inserted else { throw IngestionError(code: "invalidRelationship") }
                sheets.append(Sheet(name: title, relationshipId: relation))
            }
            if name == "workbookPr", stack == ["workbook"] {
                date1904 = ["1", "true"].contains(element.attributes["date1904"] ?? "")
            }
            stack.append(name)
        }, onText: { _ in }, onEnd: { _ in
            guard !stack.isEmpty else { throw IngestionError(code: "corruptArchive") }
            stack.removeLast()
        })
        guard hasRoot else { throw IngestionError(code: "corruptArchive") }
        return (sheets, date1904)
    }

    private static func readCells(_ archive: BoundedOfficeReader, path: String,
                                  materialized: inout Int, rawScalars: inout Int) throws -> [Cell] {
        // XML callbacks escape their argument scope but are executed synchronously.
        var cellCount = materialized
        var scalarCount = rawScalars
        var stack: [String] = []
        var cells: [Cell] = []
        var current: Cell?
        var row: Int?
        var rows = Set<Int>()
        var coordinates = Set<Int64>()
        var hasRoot = false
        var valueScalars = 0
        var inlineScalars = 0
        try archive.parse(path, onStart: { element in
            let name = role(element)
            if stack.isEmpty {
                guard name == "worksheet" else { throw IngestionError(code: "corruptArchive") }
                hasRoot = true
            }
            if name == "row", stack == ["worksheet", "sheetData"] {
                if let value = element.attributes["r"] {
                    guard let parsed = unsignedInteger(value), (1...1_048_576).contains(parsed),
                          rows.insert(parsed).inserted else { throw IngestionError(code: "invalidCell") }
                    row = parsed
                } else { row = nil }
            }
            if name == "c", stack == ["worksheet", "sheetData", "row"] {
                // This guard precedes the hook and creation of a cell record, even for blank cells.
                guard cellCount < archive.limits.cells else { throw IngestionError(code: "cellLimit") }
                try archive.hooks.event("cell", 1)
                cellCount += 1
                guard current == nil, let reference = element.attributes["r"] else {
                    throw IngestionError(code: "invalidCell")
                }
                let position = try coordinate(reference)
                guard row == nil || row == position.row,
                      coordinates.insert(Int64(position.row) * 16_384 + Int64(position.column)).inserted else {
                    throw IngestionError(code: "invalidCell")
                }
                let type = element.attributes["t"] ?? "n"
                guard ["n", "s", "inlineStr", "str", "b", "e", "d"].contains(type) else {
                    throw IngestionError(code: "invalidCell")
                }
                let style: Int?
                if let value = element.attributes["s"] {
                    guard let parsed = unsignedInteger(value) else { throw IngestionError(code: "invalidCell") }
                    style = parsed
                } else { style = nil }
                current = Cell(reference: reference, row: position.row, column: position.column, type: type, style: style)
                valueScalars = 0
                inlineScalars = 0
            } else if current != nil, stack == ["worksheet", "sheetData", "row", "c"] {
                switch name {
                case "f":
                    guard current?.formula == false else { throw IngestionError(code: "invalidCell") }
                    current?.formula = true
                case "v":
                    guard current?.valueSeen == false else { throw IngestionError(code: "invalidCell") }
                    current?.valueSeen = true
                case "is":
                    guard current?.inlineSeen == false else { throw IngestionError(code: "invalidCell") }
                    current?.inlineSeen = true
                default: break
                }
            }
            stack.append(name)
        }, onText: { text in
            guard current != nil else { return }
            if stack == ["worksheet", "sheetData", "row", "c", "v"] {
                try consume(text, total: &valueScalars, limit: archive.limits.textScalars)
                if current?.type != "s" { try consume(text, total: &scalarCount, limit: archive.limits.textScalars) }
                current?.value.append(text)
            } else if stack == ["worksheet", "sheetData", "row", "c", "is", "t"]
                        || stack == ["worksheet", "sheetData", "row", "c", "is", "r", "t"] {
                try consume(text, total: &inlineScalars, limit: archive.limits.textScalars)
                try consume(text, total: &scalarCount, limit: archive.limits.textScalars)
                current?.inline.append(text)
            }
        }, onEnd: { _ in
            if stack == ["worksheet", "sheetData", "row", "c"] {
                guard var cell = current else { throw IngestionError(code: "invalidCell") }
                if cell.type == "s", !cell.value.isEmpty {
                    guard let index = unsignedInteger(cell.value) else { throw IngestionError(code: "invalidCell") }
                    cell.sharedIndex = index
                    cell.value = ""
                }
                cells.append(cell)
                current = nil
            }
            if stack == ["worksheet", "sheetData", "row"] { row = nil }
            guard !stack.isEmpty else { throw IngestionError(code: "corruptArchive") }
            stack.removeLast()
        })
        guard hasRoot else { throw IngestionError(code: "corruptArchive") }
        materialized = cellCount
        rawScalars = scalarCount
        return cells
    }

    private static func readSharedStrings(_ archive: BoundedOfficeReader, path: String,
                                          requested: Set<Int>) throws -> [Int: String] {
        var stack: [String] = []
        var index = 0
        var active = false
        var text = ""
        var totalScalars = 0
        var result: [Int: String] = [:]
        var hasRoot = false
        try archive.parse(path, onStart: { element in
            let name = role(element)
            if stack.isEmpty {
                guard name == "sst" else { throw IngestionError(code: "corruptArchive") }
                hasRoot = true
            }
            if name == "si", stack == ["sst"] {
                active = requested.contains(index)
                text = ""
            }
            stack.append(name)
        }, onText: { value in
            guard active, stack == ["sst", "si", "t"] || stack == ["sst", "si", "r", "t"] else { return }
            try consume(value, total: &totalScalars, limit: archive.limits.textScalars)
            text.append(value)
        }, onEnd: { _ in
            if stack == ["sst", "si"] {
                if active { result[index] = text }
                guard index < Int.max else { throw IngestionError(code: "invalidCell") }
                index += 1
                active = false
                text = ""
            }
            guard !stack.isEmpty else { throw IngestionError(code: "corruptArchive") }
            stack.removeLast()
        })
        guard hasRoot else { throw IngestionError(code: "corruptArchive") }
        guard Set(result.keys) == requested else { throw IngestionError(code: "invalidCell") }
        return result
    }

    private static func readStyles(_ archive: BoundedOfficeReader, path: String,
                                   requested: Set<Int>) throws -> Set<Int> {
        var stack: [String] = []
        var index = 0
        var formatsByStyle: [Int: Int] = [:]
        var hasRoot = false
        try archive.parse(path, onStart: { element in
            let name = role(element)
            if stack.isEmpty {
                guard name == "styleSheet" else { throw IngestionError(code: "corruptArchive") }
                hasRoot = true
            }
            if name == "xf", stack == ["styleSheet", "cellXfs"] {
                if requested.contains(index) {
                    guard let format = unsignedInteger(element.attributes["numFmtId"] ?? "0") else {
                        throw IngestionError(code: "invalidCell")
                    }
                    formatsByStyle[index] = format
                }
                guard index < Int.max else { throw IngestionError(code: "invalidCell") }
                index += 1
            }
            stack.append(name)
        }, onText: { _ in }, onEnd: { _ in
            guard !stack.isEmpty else { throw IngestionError(code: "corruptArchive") }
            stack.removeLast()
        })
        guard hasRoot else { throw IngestionError(code: "corruptArchive") }
        guard Set(formatsByStyle.keys) == requested else { throw IngestionError(code: "invalidCell") }
        // Built-in ids (< 164) use the built-in table; every used custom id must be defined exactly once.
        let usedFormats = Set(formatsByStyle.values.filter { $0 >= 164 })
        var custom: [Int: Bool] = [:]
        var formatScalars = 0
        try archive.parse(path, onStart: { element in
            let name = role(element)
            if name == "numFmt", stack == ["styleSheet", "numFmts"] {
                guard let idValue = element.attributes["numFmtId"], let id = unsignedInteger(idValue) else {
                    throw IngestionError(code: "invalidCell")
                }
                if usedFormats.contains(id) {
                    guard custom[id] == nil, let format = element.attributes["formatCode"] else {
                        throw IngestionError(code: "invalidCell")
                    }
                    try consume(format, total: &formatScalars, limit: archive.limits.textScalars)
                    custom[id] = SpreadsheetText.isDateFormat(format)
                }
            }
            stack.append(name)
        }, onText: { _ in }, onEnd: { _ in
            guard !stack.isEmpty else { throw IngestionError(code: "corruptArchive") }
            stack.removeLast()
        })
        guard Set(custom.keys) == usedFormats else { throw IngestionError(code: "invalidCell") }
        return Set(formatsByStyle.compactMap { style, format in
            (format >= 164 ? custom[format] == true : SpreadsheetText.isBuiltInDate(format)) ? style : nil
        })
    }

    /// §3: the normalized value of one cell, or "" when the cell is omitted
    /// (empty, error value, or formula without a cached value).
    private static func render(_ cell: Cell, strings: [Int: String], dateStyles: Set<Int>, date1904: Bool) throws -> String {
        let value: String
        switch cell.type {
        case "s":
            guard let index = cell.sharedIndex else { return "" }
            guard let shared = strings[index] else { throw IngestionError(code: "invalidCell") }
            value = shared
        case "inlineStr":
            value = cell.inline
        case "e":
            return ""
        case "b":
            switch cell.value {
            case "": return ""
            case "0": value = "FALSE"
            case "1": value = "TRUE"
            default: throw IngestionError(code: "invalidCell")
            }
        case "n" where !cell.value.isEmpty:
            let date = dateStyles.contains(cell.style ?? 0) ? SpreadsheetText.date(cell.value, date1904: date1904) : nil
            value = date ?? SpreadsheetText.number(cell.value) ?? cell.value
        default:
            value = cell.value
        }
        return SpreadsheetText.normalize(value)
    }

    private static func role(_ element: OfficeXMLElement) -> String {
        mainNamespaces.contains(element.namespaceURI) ? element.name : ""
    }

    private static func isRelationship(_ type: String, kind: String) -> Bool {
        relationshipNamespaces.contains { type == $0 + "/" + kind }
    }

    private static func requiredPart(_ relationships: [String: OfficeRelationship], kind: String,
                                     fallback: String? = nil) throws -> String {
        let found = relationships.values.filter { isRelationship($0.type, kind: kind) }
        if found.isEmpty, let fallback { return fallback }
        guard found.count == 1, let relationship = found.first else { throw IngestionError(code: "invalidRelationship") }
        return relationship.target
    }

    private static func unsignedInteger(_ value: String) -> Int? {
        guard !value.isEmpty else { return nil }
        var result = 0
        for byte in value.utf8 {
            guard (48...57).contains(byte) else { return nil }
            let multiplied = result.multipliedReportingOverflow(by: 10)
            let added = multiplied.partialValue.addingReportingOverflow(Int(byte - 48))
            guard !multiplied.overflow, !added.overflow else { return nil }
            result = added.partialValue
        }
        return result
    }

    private static func coordinate(_ reference: String) throws -> (row: Int, column: Int) {
        guard (2...10).contains(reference.utf8.count) else { throw IngestionError(code: "invalidCell") }
        let bytes = Array(reference.utf8)
        var index = 0
        var column = 0
        while index < bytes.count, (65...90).contains(bytes[index]) {
            guard column <= 16_384 / 26 else { throw IngestionError(code: "invalidCell") }
            column = column * 26 + Int(bytes[index] - 64)
            index += 1
        }
        guard (1...16_384).contains(column), index < bytes.count, bytes[index] != 48,
              let row = unsignedInteger(String(decoding: bytes[index...], as: UTF8.self)),
              (1...1_048_576).contains(row) else { throw IngestionError(code: "invalidCell") }
        return (row, column)
    }

    private static func consume(_ value: String, total: inout Int, limit: Int) throws {
        let remaining = limit - total
        var count = 0
        for _ in value.unicodeScalars {
            guard count < remaining else { throw IngestionError(code: "textLimit") }
            count += 1
        }
        total += count
    }
}
