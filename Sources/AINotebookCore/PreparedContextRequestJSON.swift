import Foundation

/// The prepared-request wire shape contains only the frozen contract fields.
public enum PreparedContextRequestJSON {
    public static func encode(_ request: PreparedContextRequest) throws -> Data {
        try canonicalData(object(request))
    }

    public static func decode(_ bytes: Data) throws -> PreparedContextRequest {
        try JSONDecoder().decode(PreparedContextRequest.self, from: bytes)
    }

    public static func object(_ request: PreparedContextRequest) throws -> NSDictionary {
        var options: [String: Any] = [:]
        if let value = request.options.numCtx { options["numCtx"] = value }
        if let value = request.options.maxTokens { options["maxTokens"] = value }

        // Use the persisted citation codec's field/omission rules. Its envelope
        // belongs to storage; a prepared request embeds just the items array.
        let citations: [Any]
        if request.citationMap.isEmpty {
            citations = []
        } else {
            guard let encoded = CitationsCodec.encode(request.citationMap),
                  let data = encoded.data(using: .utf8) else {
                throw ContextPackError.invalidInput
            }
            let encodedObject = try JSONSerialization.jsonObject(with: data)
            if let envelope = encodedObject as? [String: Any],
               let items = envelope["items"] as? [Any] {
                citations = items
            } else if let items = encodedObject as? [Any] {
                citations = items
            } else {
                throw ContextPackError.invalidInput
            }
        }

        let corpus = request.coverage.corpus
        let turn = request.coverage.turn
        let result: [String: Any] = [
            "estimatorVersion": request.estimatorVersion,
            "model": [
                "providerId": request.model.providerId,
                "model": request.model.model,
                "runtimeContext": request.model.runtimeContext,
                "maxOutputTokens": request.model.maxOutputTokens,
                "contextWindowKnown": request.model.contextWindowKnown
            ] as [String: Any],
            "messages": request.messages.map { message -> [String: Any] in
                ["role": message.role, "sections": message.sections.map { section -> [String: Any] in
                    ["kind": section.kind, "text": section.text, "tokens": section.tokens]
                }]
            },
            "options": options,
            "citationMap": citations,
            "included": request.included.map { ["kind": $0.kind, "id": $0.id] },
            "omitted": request.omitted.map { ["kind": $0.kind, "id": $0.id, "reason": $0.reason] },
            "coverage": [
                "corpus": [
                    "filesInScope": corpus.filesInScope,
                    "searchable": corpus.searchable,
                    "pending": corpus.pending,
                    "error": corpus.error,
                    "skipped": corpus.skipped,
                    "missing": corpus.missing,
                    "unavailable": corpus.unavailable,
                    "refreshPending": corpus.refreshPending,
                    "refreshError": corpus.refreshError,
                    "partial": corpus.partial
                ] as [String: Any],
                "turn": [
                    "passages": turn.passages,
                    "filesIncluded": turn.filesIncluded,
                    "candidatesWithPublishedChunks": turn.candidatesWithPublishedChunks,
                    "overview": turn.overview
                ] as [String: Any]
            ],
            "generationId": request.generationId.map { $0 as Any } ?? NSNull(),
            "sourceRevisions": request.sourceRevisions.map {
                ["sourceId": $0.sourceId, "revisionId": $0.revisionId]
            }
        ]
        return result as NSDictionary
    }

    /// Matches the shared oracle's compact, scalar-key-sorted UTF-8 JSON.
    /// Unicode is emitted literally; only JSON-required characters are escaped.
    public static func canonicalData(_ object: Any) throws -> Data {
        var output = ""
        try write(object, to: &output)
        return Data(output.utf8)
    }

    private static func write(_ value: Any, to output: inout String) throws {
        if value is NSNull {
            output += "null"
        } else if let object = value as? NSDictionary {
            // Do not bridge to Dictionary<String, Any>: Swift String equality
            // would collapse canonically equivalent, scalar-distinct JSON keys.
            let keys = object.allKeys.compactMap { $0 as? String }
            guard keys.count == object.count else { throw ContextPackError.invalidInput }
            output += "{"
            for (index, key) in keys.sorted(by: ContextPackAlgorithms.scalarLess).enumerated() {
                if index > 0 { output += "," }
                writeString(key, to: &output)
                output += ":"
                try write(object[key]!, to: &output)
            }
            output += "}"
        } else if let array = value as? [Any] {
            output += "["
            for (index, element) in array.enumerated() {
                if index > 0 { output += "," }
                try write(element, to: &output)
            }
            output += "]"
        } else if let string = value as? String {
            writeString(string, to: &output)
        } else if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                output += number.boolValue ? "true" : "false"
            } else {
                guard number.doubleValue.isFinite else { throw ContextPackError.invalidInput }
                output += number.stringValue
            }
        } else {
            throw ContextPackError.invalidInput
        }
    }

    private static func writeString(_ value: String, to output: inout String) {
        output += "\""
        let hex = Array("0123456789abcdef".utf8)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: output += "\\\""
            case 0x5c: output += "\\\\"
            case 0x08: output += "\\b"
            case 0x0c: output += "\\f"
            case 0x0a: output += "\\n"
            case 0x0d: output += "\\r"
            case 0x09: output += "\\t"
            case 0...0x1f:
                output += "\\u00"
                output.unicodeScalars.append(Unicode.Scalar(hex[Int(scalar.value >> 4)]))
                output.unicodeScalars.append(Unicode.Scalar(hex[Int(scalar.value & 0xf)]))
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}
