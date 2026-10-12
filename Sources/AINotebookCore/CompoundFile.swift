import Foundation

/// One read/decoded byte counter per document (`maxOfficeDecompressedBytes`).
final class MailByteBudget {
    private let maximum: Int64
    private(set) var used: Int64 = 0
    init(maximum: Int64) { self.maximum = maximum }

    func accept(_ count: Int) throws {
        guard count >= 0, Int64(count) <= maximum - used else { throw IngestionError(code: "officeLimit") }
        used += Int64(count)
    }
}

/// Bounded, dependency-free reader of the OLE Compound File Binary format
/// (MS-CFB) used by Outlook `.msg` files (contract `ingestion-mail-v1`; same
/// rules as Windows `CompoundFile`). Every sector chain is loop-checked, every
/// index range-checked, directory traversal is iterative and cycle-checked, and
/// every sector read is debited from the document byte budget. Structural damage
/// is `corruptArchive`; exceeding a bound is `officeLimit`. Stream contents are
/// read only on demand (attachment payloads never).
final class CompoundFile {
    static let magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    static let maxEntries = 100_000
    private static let endOfChain: UInt32 = 0xFFFF_FFFE
    private static let freeSector: UInt32 = 0xFFFF_FFFF
    private static let noStream: UInt32 = 0xFFFF_FFFF

    struct Entry {
        let name: String
        let kind: UInt8
        let left: UInt32
        let right: UInt32
        let child: UInt32
        let start: UInt32
        let size: UInt64
    }

    private let data: [UInt8]
    private let budget: MailByteBudget
    private let sectorSize: Int
    private let sectorCount: Int
    private let firstMiniFAT: UInt32
    private var fat: [UInt32] = []
    private(set) var entries: [Entry] = []
    private var miniStream: [UInt8]?
    private var miniFAT: [UInt32] = []

    private static func corrupt() -> IngestionError { IngestionError(code: "corruptArchive") }

    static func u16(_ data: [UInt8], _ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
    static func u32(_ data: [UInt8], _ at: Int) -> UInt32 {
        UInt32(data[at]) | UInt32(data[at + 1]) << 8 | UInt32(data[at + 2]) << 16 | UInt32(data[at + 3]) << 24
    }

    init(data: [UInt8], budget: MailByteBudget) throws {
        self.data = data
        self.budget = budget
        guard data.count >= 512, Array(data[0..<8]) == Self.magic else { throw Self.corrupt() }
        let major = Self.u16(data, 26), order = Self.u16(data, 28), shift = Self.u16(data, 30), miniShift = Self.u16(data, 32)
        guard order == 0xFFFE, miniShift == 6, Self.u32(data, 56) == 4096,
              (major == 3 && shift == 9) || (major == 4 && shift == 12) else { throw Self.corrupt() }
        sectorSize = 1 << shift
        guard data.count >= sectorSize else { throw Self.corrupt() }
        sectorCount = (data.count - sectorSize + sectorSize - 1) / sectorSize
        let fatCount = Int(Self.u32(data, 44)), firstDirectory = Self.u32(data, 48)
        firstMiniFAT = Self.u32(data, 60)
        let firstDIFAT = Self.u32(data, 68), difatCount = Int(Self.u32(data, 72))
        guard fatCount <= sectorCount, difatCount <= sectorCount else { throw Self.corrupt() }
        var difat = (0..<109).map { Self.u32(data, 76 + 4 * $0) }
        var sector = firstDIFAT
        var seen = Set<UInt32>()
        let perSector = sectorSize / 4 - 1
        for _ in 0..<difatCount {
            try Task.checkCancellation()
            guard Int(sector) < sectorCount, seen.insert(sector).inserted else { throw Self.corrupt() }
            let block = try read(sector: sector)
            difat += (0..<perSector).map { Self.u32(block, 4 * $0) }
            sector = Self.u32(block, 4 * perSector)
        }
        let fatSectors = Array(difat.filter { $0 != Self.freeSector }.prefix(fatCount))
        guard fatSectors.count == fatCount, fatSectors.allSatisfy({ Int($0) < sectorCount }),
              Set(fatSectors).count == fatSectors.count else { throw Self.corrupt() }
        fat.reserveCapacity(fatCount * sectorSize / 4)
        for sector in fatSectors {
            try Task.checkCancellation()
            let block = try read(sector: sector)
            for k in 0..<(sectorSize / 4) { fat.append(Self.u32(block, 4 * k)) }
        }
        let directory = try chainBytes(start: firstDirectory, size: nil)
        guard directory.count / 128 <= Self.maxEntries else { throw IngestionError(code: "officeLimit") }
        for k in 0..<(directory.count / 128) {
            let raw = Array(directory[(128 * k)..<(128 * k + 128)])
            let nameLength = Self.u16(raw, 64), kind = raw[66]
            guard [0, 1, 2, 5].contains(kind) else { throw Self.corrupt() }
            if kind != 0, nameLength < 2 || nameLength > 64 || nameLength % 2 == 1 { throw Self.corrupt() }
            let name = kind == 0 ? "" : MailText.utf16LE(Array(raw[0..<(nameLength - 2)]))
            let low = UInt64(Self.u32(raw, 120)), high = UInt64(Self.u32(raw, 124))
            entries.append(Entry(name: name, kind: kind, left: Self.u32(raw, 68), right: Self.u32(raw, 72),
                                 child: Self.u32(raw, 76), start: Self.u32(raw, 116),
                                 size: major == 3 ? low : low | high << 32))
        }
        guard let root = entries.first, root.kind == 5 else { throw Self.corrupt() }
    }

    private func read(sector index: UInt32) throws -> [UInt8] {
        let offset = (Int(index) + 1) * sectorSize
        try budget.accept(sectorSize)
        var block = Array(data[min(offset, data.count)..<min(offset + sectorSize, data.count)])
        if block.count < sectorSize { block += [UInt8](repeating: 0, count: sectorSize - block.count) }
        return block
    }

    /// Sector indices from `start`; stops after `needed` sectors (nil: at ENDOFCHAIN).
    private func chain(start: UInt32, needed: Int?, table: [UInt32], limit: Int) throws -> [UInt32] {
        var out: [UInt32] = []
        var seen = Set<UInt32>()
        var sector = start
        while sector != Self.endOfChain {
            if let needed, out.count >= needed { break }
            try Task.checkCancellation()
            guard Int(sector) < limit, Int(sector) < table.count, seen.insert(sector).inserted else { throw Self.corrupt() }
            out.append(sector)
            sector = table[Int(sector)]
        }
        if let needed, out.count < needed { throw Self.corrupt() }
        return out
    }

    private func chainBytes(start: UInt32, size: Int?) throws -> [UInt8] {
        let needed = size.map { ($0 + sectorSize - 1) / sectorSize }
        var bytes: [UInt8] = []
        for sector in try chain(start: start, needed: needed, table: fat, limit: sectorCount) {
            bytes += try read(sector: sector)
        }
        if let size { bytes.removeLast(bytes.count - size) }
        return bytes
    }

    /// Child storages/streams of `index` keyed by ASCII-uppercased name, in-order; the first name wins.
    func children(of index: Int) throws -> [String: Int] {
        var result: [String: Int] = [:]
        var seen = Set<UInt32>()
        var stack: [UInt32] = []
        var node = entries[index].child
        while !stack.isEmpty || node != Self.noStream {
            while node != Self.noStream {
                guard Int(node) < entries.count, seen.insert(node).inserted else { throw Self.corrupt() }
                stack.append(node)
                node = entries[Int(node)].left
            }
            let current = stack.removeLast()
            let entry = entries[Int(current)]
            if entry.kind == 1 || entry.kind == 2 {
                let key = MailText.asciiUpper(entry.name)
                if result[key] == nil { result[key] = Int(current) }
            }
            node = entry.right
        }
        return result
    }

    func stream(_ index: Int) throws -> [UInt8] {
        let entry = entries[index]
        guard entry.kind == 2 else { throw Self.corrupt() }
        guard entry.size <= UInt64(data.count) else { throw Self.corrupt() }
        let size = Int(entry.size)
        if size == 0 { return [] }
        if size >= 4096 { return try chainBytes(start: entry.start, size: size) }
        if miniStream == nil {
            let root = entries[0]
            guard root.size <= UInt64(data.count) else { throw Self.corrupt() }
            miniStream = root.size == 0 ? [] : try chainBytes(start: root.start, size: Int(root.size))
            let table = firstMiniFAT == Self.endOfChain ? [] : try chainBytes(start: firstMiniFAT, size: nil)
            miniFAT = (0..<(table.count / 4)).map { Self.u32(table, 4 * $0) }
        }
        let mini = miniStream!
        let sectors = try chain(start: entry.start, needed: (size + 63) / 64, table: miniFAT, limit: (mini.count + 63) / 64)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(sectors.count * 64)
        for sector in sectors {
            let offset = Int(sector) * 64
            bytes += mini[offset..<min(offset + 64, mini.count)]
        }
        guard bytes.count >= size else { throw Self.corrupt() }
        return Array(bytes.prefix(size))
    }
}
