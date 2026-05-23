import Foundation

public struct OllamaModel: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let modifiedAt: String
    public let size: Int64
    public let digest: String
    public let details: Details

    public struct Details: Codable, Equatable, Hashable, Sendable {
        public let format: String?
        public let family: String?
        public let parameterSize: String?
        public let quantizationLevel: String?

        enum CodingKeys: String, CodingKey {
            case format
            case family
            case parameterSize = "parameter_size"
            case quantizationLevel = "quantization_level"
        }
    }

    enum CodingKeys: String, CodingKey {
        case name
        case modifiedAt = "modified_at"
        case size
        case digest
        case details
    }
}

public struct OllamaModelList: Codable, Equatable, Sendable {
    public let models: [OllamaModel]
}
