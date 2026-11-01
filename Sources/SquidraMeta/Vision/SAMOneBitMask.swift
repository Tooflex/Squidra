// Copyright (c) Meta Platforms, Inc. and affiliates. All Rights Reserved.
// Swift adaptation of meta-sam-parser 0.1.0 one_bit codec, under SAM License.
// See ThirdPartyLicenses/meta-sam-parser.{LICENSE,NOTICE} for attribution/changes.
import Foundation

public enum SAMDecodeError: Error, Equatable, Sendable {
    case invalidMask, unsupportedEncoding, invalidGeometry, resourceLimit, deadlineExceeded
}
/// Native bounded profile for the explicitly requested one_bit encoding.
/// Canonical re-encoding validates finalization as well as the packed envelope.
public enum SAMOneBitMask {
    static let maximumPayloadBytes = 196_608
    private static let alphabet = Array((UInt8(33)...UInt8(123)).filter { ![34,92,44,59,60,62,124].contains($0) })
    private static let digits: [Int] = {
        var values = Array(repeating:-1,count:128)
        for (index,byte) in alphabet.enumerated() { values[Int(byte)] = index };return values
    }()
    static func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw SAMDecodeError.deadlineExceeded }
    }
    public static func decode(_ payload: String, width: Int, height: Int,
                              deadline: ContinuousClock.Instant) throws -> Data {
        try check(deadline)
        guard (1...1024).contains(width),(1...1024).contains(height),width*height <= 1_048_576,
              payload.utf8.count <= maximumPayloadBytes else { throw SAMDecodeError.resourceLimit }
        let bytes = Array(payload.utf8)
        guard bytes.first == 33 else { throw SAMDecodeError.unsupportedEncoding }
        let packed = try unpack(Array(bytes.dropFirst()))
        var decoder = try RangeDecoder(packed)
        var counts = Array(repeating:UInt32(1),count:8192)
        let stride = width+4
        var padded = Array(repeating:UInt8(0),count:stride*(height+2))
        var raster = Array(repeating:UInt8(0),count:width*height)
        for y in 0..<height {
            try check(deadline)
            for x in 0..<width {
                let position = (y+2)*stride+2+x
                let offset = context(padded,position:position,stride:stride)*2
                let zero = counts[offset],one = counts[offset+1]
                let bit: UInt8 = try decoder.frequency(zero+one) < zero ? 0 : 1
                try decoder.decode(bit == 0 ? 0 : zero,frequency:bit == 0 ? zero : one)
                padded[position] = bit;raster[y*width+x] = bit
                update(&counts,offset:offset,bit:bit)
            }
        }
        guard try encode(raster,width:width,height:height,deadline:deadline) == bytes else { throw SAMDecodeError.invalidMask }
        return Data(raster)
    }
    private static func context(_ p: [UInt8], position: Int, stride: Int) -> Int {
        let prior = position-stride,earlier = prior-stride
        var value = Int(p[position-1])
        value |= Int(p[position-2]) << 1
        value |= Int(p[prior-2]) << 2
        value |= Int(p[prior-1]) << 3
        value |= Int(p[prior]) << 4
        value |= Int(p[prior+1]) << 5
        value |= Int(p[prior+2]) << 6
        value |= Int(p[earlier-2]) << 7
        value |= Int(p[earlier-1]) << 8
        value |= Int(p[earlier]) << 9
        value |= Int(p[earlier+1]) << 10
        value |= Int(p[earlier+2]) << 11
        return value
    }
    private static func update(_ counts: inout [UInt32], offset: Int, bit: UInt8) {
        counts[offset+Int(bit)] += 14
        if counts[offset]+counts[offset+1] >= 4096 {
            counts[offset] = max(1,counts[offset] >> 1);counts[offset+1] = max(1,counts[offset+1] >> 1)
        }
    }
    private static func encode(_ raster: [UInt8], width: Int, height: Int, deadline: ContinuousClock.Instant) throws -> [UInt8] {
        var encoder = RangeEncoder(),counts = Array(repeating:UInt32(1),count:8192)
        let stride = width+4
        var padded = Array(repeating:UInt8(0),count:stride*(height+2))
        for y in 0..<height {
            try check(deadline)
            for x in 0..<width {
                let position = (y+2)*stride+2+x,bit = raster[y*width+x]
                let offset = context(padded,position:position,stride:stride)*2
                let zero = counts[offset],one = counts[offset+1]
                try encoder.encode(bit == 0 ? 0 : zero,frequency:bit == 0 ? zero : one,total:zero+one)
                padded[position] = bit;update(&counts,offset:offset,bit:bit)
            }
        }
        return [33]+pack(encoder.finish())
    }
    private static func pack(_ input: [UInt8]) -> [UInt8] {
        func group(_ original: UInt64) -> [UInt8] {
            var value = original,result = Array(repeating:UInt8(0),count:5)
            for index in (0..<5).reversed() { result[index] = alphabet[Int(value%85)];value /= 85 };return result
        }
        var output = group(UInt64(input.count)),offset = 0
        while offset < input.count {
            let count = min(4,input.count-offset)
            var value: UInt64 = 0
            for index in 0..<4 { value = (value << 8) | (index<count ? UInt64(input[offset+index]) : 0) }
            output.append(contentsOf:group(value).prefix(count == 4 ? 5 : count+1));offset += count
        }
        return output
    }
    private static func unpack(_ input: [UInt8]) throws -> [UInt8] {
        guard input.count >= 5,input.allSatisfy({ $0 < 128 && digits[Int($0)] >= 0 }) else { throw SAMDecodeError.invalidMask }
        func group(_ start: Int, count: Int = 5) -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<5 { value = value*85 + (index<count ? UInt64(digits[Int(input[start+index])]) : 84) };return value
        }
        let length64 = group(0)
        guard length64 <= UInt64(maximumPayloadBytes) else { throw SAMDecodeError.resourceLimit }
        let length = Int(length64),remainder = length%4
        guard input.count == 5+(length/4)*5+(remainder == 0 ? 0 : remainder+1) else { throw SAMDecodeError.invalidMask }
        var output: [UInt8] = [];output.reserveCapacity(length)
        var source = 5
        while output.count < length {
            let count = min(4,length-output.count),value = group(source,count:count == 4 ? 5 : count+1)
            guard value <= UInt32.max else { throw SAMDecodeError.invalidMask }
            for index in 0..<count { output.append(UInt8((value >> (24-index*8)) & 255)) }
            source += count == 4 ? 5 : count+1
        }
        guard pack(output) == input else { throw SAMDecodeError.invalidMask };return output
    }
    private struct RangeDecoder {
        var low: UInt32 = 0,range: UInt32 = .max,code: UInt32 = 0,scaled: UInt32 = 0
        let input: [UInt8]
        var position = 0
        init(_ input: [UInt8]) throws {
            guard input.count >= 4 else { throw SAMDecodeError.invalidMask }
            self.input = input
            for _ in 0..<4 { code = (code << 8) | UInt32(try read()) }
        }
        mutating func read() throws -> UInt8 {
            guard position < input.count else { throw SAMDecodeError.invalidMask }
            defer { position += 1 };return input[position]
        }
        mutating func frequency(_ total: UInt32) throws -> UInt32 {
            scaled = range/total
            guard scaled > 0 else { throw SAMDecodeError.invalidMask }
            return min(total-1,(code &- low)/scaled)
        }
        mutating func decode(_ cumulative: UInt32, frequency: UInt32) throws {
            low = low &+ scaled*cumulative;range = scaled*frequency
            var iterations = 0
            while true {
                if (low ^ (low &+ range)) < 1<<24 { }
                else if range < 1<<16 { range = (0 &- low) & 0xffff }
                else { break }
                iterations += 1;guard iterations <= 8 else { throw SAMDecodeError.invalidMask }
                code = (code << 8) | UInt32(try read());low <<= 8;range <<= 8
            }
        }
    }
    private struct RangeEncoder {
        var low: UInt32 = 0,range: UInt32 = .max
        var output: [UInt8] = []
        mutating func encode(_ cumulative: UInt32, frequency: UInt32, total: UInt32) throws {
            let scaled = range/total
            guard scaled > 0 else { throw SAMDecodeError.invalidMask }
            low = low &+ scaled*cumulative;range = scaled*frequency
            var iterations = 0
            while true {
                if (low ^ (low &+ range)) < 1<<24 { }
                else if range < 1<<16 { range = (0 &- low) & 0xffff }
                else { break }
                iterations += 1
                guard iterations <= 8,output.count < maximumPayloadBytes else { throw SAMDecodeError.invalidMask }
                output.append(UInt8(low >> 24));low <<= 8;range <<= 8
            }
        }
        mutating func finish() -> [UInt8] {
            for _ in 0..<4 { output.append(UInt8(low >> 24));low <<= 8 };return output
        }
    }
}
