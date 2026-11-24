import Foundation

/// Writes the few protobuf fields a SABR request needs. Protobuf is a compact binary format:
/// each field is its number and wire type, then the value.
struct SABRWriter {
    private(set) var data = Data()

    mutating func int(_ field: Int, _ value: Int?) {
        guard let value else { return }
        key(field, wireType: 0)
        varint(UInt64(bitPattern: Int64(value)))
    }

    mutating func bool(_ field: Int, _ value: Bool) {
        int(field, value ? 1 : 0)
    }

    mutating func bytes(_ field: Int, _ value: Data?) {
        guard let value else { return }
        key(field, wireType: 2)
        varint(UInt64(value.count))
        data.append(value)
    }

    mutating func string(_ field: Int, _ value: String?) {
        bytes(field, value.map { Data($0.utf8) })
    }

    mutating func message(_ field: Int, _ build: (inout SABRWriter) -> Void) {
        var inner = SABRWriter()
        build(&inner)
        bytes(field, inner.data)
    }

    private mutating func key(_ field: Int, wireType: UInt64) {
        varint(UInt64(field) << 3 | wireType)
    }

    private mutating func varint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            data.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }
}

/// Reads a protobuf message into its fields, keeping every value of a repeated field.
struct SABRMessage {
    private enum Value {
        case number(UInt64)
        case bytes(Data)
    }

    private var fields: [Int: [Value]] = [:]

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        var index = 0
        func varint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]
                index += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return result }
                shift += 7
            }
            return nil
        }
        while index < bytes.count {
            guard let key = varint() else { return nil }
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let value = varint() else { return nil }
                fields[field, default: []].append(.number(value))
            case 1, 5:
                let size = key & 7 == 1 ? 8 : 4
                guard index + size <= bytes.count else { return nil }
                let value = bytes[index..<index + size].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                fields[field, default: []].append(.number(value))
                index += size
            case 2:
                guard let length = varint(), index + Int(length) <= bytes.count else { return nil }
                fields[field, default: []].append(.bytes(Data(bytes[index..<index + Int(length)])))
                index += Int(length)
            default:
                return nil
            }
        }
    }

    func int(_ field: Int) -> Int? {
        guard case .number(let value)? = fields[field]?.last else { return nil }
        return Int(truncatingIfNeeded: value)
    }

    func bool(_ field: Int) -> Bool { int(field) == 1 }

    func data(_ field: Int) -> Data? {
        guard case .bytes(let value)? = fields[field]?.last else { return nil }
        return value
    }

    func string(_ field: Int) -> String? {
        data(field).map { String(decoding: $0, as: UTF8.self) }
    }

    func message(_ field: Int) -> SABRMessage? {
        data(field).flatMap(SABRMessage.init)
    }

    /// A repeated number, sent one by one or packed into one run of bytes.
    func ints(_ field: Int) -> [Int] {
        (fields[field] ?? []).flatMap { value -> [Int] in
            switch value {
            case .number(let number):
                return [Int(truncatingIfNeeded: number)]
            case .bytes(let packed):
                var numbers: [Int] = []
                var current: UInt64 = 0
                var shift: UInt64 = 0
                for byte in packed {
                    current |= UInt64(byte & 0x7F) << shift
                    shift += 7
                    if byte < 0x80 {
                        numbers.append(Int(truncatingIfNeeded: current))
                        current = 0
                        shift = 0
                    }
                }
                return numbers
            }
        }
    }
}

/// One piece of a SABR answer. UMP is YouTube's envelope: a list of typed parts, each with its size.
struct UMPPart {
    let type: Int
    let payload: Data
}

enum UMP {
    /// UMP's own variable-length number: the first byte says how many bytes follow. It isn't protobuf's.
    static func varint(_ bytes: [UInt8], at index: Int) -> (value: Int, length: Int)? {
        guard index < bytes.count else { return nil }
        let first = Int(bytes[index])
        let length = first < 0x80 ? 1 : first < 0xC0 ? 2 : first < 0xE0 ? 3 : first < 0xF0 ? 4 : 5
        guard index + length <= bytes.count else { return nil }
        let rest = bytes[index + 1..<index + length].map(Int.init)
        switch length {
        case 1: return (first, 1)
        case 2: return ((first & 0x3F) | rest[0] << 6, 2)
        case 3: return ((first & 0x1F) | rest[0] << 5 | rest[1] << 13, 3)
        case 4: return ((first & 0x0F) | rest[0] << 4 | rest[1] << 12 | rest[2] << 20, 4)
        default: return (rest[0] | rest[1] << 8 | rest[2] << 16 | rest[3] << 24, 5)
        }
    }

    static func parts(_ data: Data) -> [UMPPart] {
        let bytes = [UInt8](data)
        var parts: [UMPPart] = []
        var index = 0
        while let type = varint(bytes, at: index),
              let size = varint(bytes, at: index + type.length) {
            let start = index + type.length + size.length
            guard start + size.value <= bytes.count else { break }
            parts.append(UMPPart(type: type.value, payload: Data(bytes[start..<start + size.value])))
            index = start + size.value
        }
        return parts
    }

    static func selfCheck() {
        assert(varint([0x05], at: 0)?.value == 5)
        assert(varint([0x81, 0x02], at: 0)?.value == 1 | 2 << 6 && varint([0x81, 0x02], at: 0)?.length == 2)
        assert(varint([0xF0, 0x01, 0x00, 0x00, 0x00], at: 0)?.value == 1)
        let body: [UInt8] = [20, 2, 0xAA, 0xBB, 21, 1, 0xCC]
        let read = parts(Data(body))
        assert(read.map(\.type) == [20, 21] && read[0].payload == Data([0xAA, 0xBB]) && read[1].payload == Data([0xCC]))
        var writer = SABRWriter()
        writer.int(28, 90_000)
        writer.string(3, "x")
        writer.message(1) { $0.int(1, -1) }
        writer.bytes(6, Data([1, 0x96, 0x01]))
        let message = SABRMessage(writer.data)
        assert(message?.int(28) == 90_000 && message?.string(3) == "x" && message?.message(1)?.int(1) == -1)
        assert(message?.ints(6) == [1, 150])
    }
}
