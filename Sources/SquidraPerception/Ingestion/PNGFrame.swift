import Foundation

/// Bounded PNG envelope validation, not image decompression. Currently supports
/// only noninterlaced 8-bit RGB/RGBA. A real decoder needs separate qualification.
public struct PNGFrame: Sendable {
    public static let maximumBytes = 4 * 1024 * 1024
    public let bytes: Data
    public let width: Int, height: Int
    public init(bytes: Data, mediaType: String) throws {
        guard bytes.count <= Self.maximumBytes else { throw VisionError.mediaTooLarge }
        guard mediaType == "image/png", bytes.count >= 57,
              Array(bytes.prefix(8)) == [137,80,78,71,13,10,26,10] else { throw VisionError.invalidMedia }
        // Normalize indices: Foundation Data slices can retain nonzero startIndex.
        let data = Array(bytes)
        func uint32(_ offset: Int) -> UInt32 {
            data[offset..<offset+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        var offset = 8, chunks = 0, width = 0, height = 0
        var sawHeader = false, sawData = false, endedData = false, sawEnd = false
        var compressedBytes = 0
        while offset < data.count {
            chunks += 1
            guard chunks <= 128, offset <= data.count - 12 else { throw VisionError.invalidMedia }
            let length = Int(uint32(offset))
            guard length <= data.count - offset - 12 else { throw VisionError.invalidMedia }
            let typeBytes = Array(data[offset+4..<offset+8])
            guard typeBytes.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
                  (65...90).contains(typeBytes[2]) else { throw VisionError.invalidMedia }
            let type = String(decoding: typeBytes, as: UTF8.self)
            let end = offset + 8 + length
            var crc: UInt32 = 0xffffffff
            for byte in data[offset+4..<end] { crc = Self.crcTable[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
            guard crc ^ 0xffffffff == uint32(end) else { throw VisionError.invalidMedia }
            if !sawHeader {
                guard type == "IHDR", length == 13 else { throw VisionError.invalidMedia }
                width = Int(uint32(offset+8)); height = Int(uint32(offset+12))
                guard (1...2048).contains(width), (1...2048).contains(height),
                      data[offset+16] == 8, [UInt8(2),6].contains(data[offset+17]),
                      data[offset+18] == 0, data[offset+19] == 0, data[offset+20] == 0 else { throw VisionError.invalidMedia }
                sawHeader = true
            } else if type == "IDAT" {
                guard !endedData else { throw VisionError.invalidMedia }; sawData = true
                compressedBytes += length
            } else if type == "IEND" {
                guard length == 0, sawData, compressedBytes > 0, end + 4 == data.count else { throw VisionError.invalidMedia }
                sawEnd = true
            } else {
                // Reject unknown critical chunks and animation; ancillary data
                // is bounded by the same byte/chunk budgets and CRC validation.
                guard typeBytes[0] >= 97, !["acTL","fcTL","fdAT"].contains(type) else { throw VisionError.invalidMedia }
                if sawData { endedData = true }
            }
            offset = end + 4
        }
        guard sawEnd else { throw VisionError.invalidMedia }
        self.bytes = Data(bytes); self.width = width; self.height = height
    }
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? 0xedb88320 ^ (crc >> 1) : crc >> 1 }
        return crc
    }
}
