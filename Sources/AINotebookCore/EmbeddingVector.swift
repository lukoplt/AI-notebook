import Foundation

public struct EmbeddingVector: Equatable, Hashable, Sendable {
    public let values: [Float]

    public var dim: Int { values.count }

    public init(values: [Float]) {
        self.values = values
    }

    public enum DecodeError: Error, Equatable {
        case misalignedByteCount(Int)
    }

    public init(data: Data) throws {
        guard data.count % MemoryLayout<Float>.size == 0 else {
            throw DecodeError.misalignedByteCount(data.count)
        }
        let count = data.count / MemoryLayout<Float>.size
        var arr = [Float](repeating: 0, count: count)
        _ = arr.withUnsafeMutableBytes { dst in
            data.copyBytes(to: dst)
        }
        self.values = arr
    }

    public func asData() -> Data {
        values.withUnsafeBufferPointer { buf in
            Data(buffer: buf)
        }
    }
}
