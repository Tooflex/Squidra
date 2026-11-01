import Foundation
import SquidraDomain
import SquidraPerception

public struct SAMImageDetection: Equatable, Sendable {
    public let localID: String, box: PixelBox, mask: BinaryMask
    public let boxConfidence: Confidence?, maskConfidence: Confidence?
}
/// Strict bounded image profile. No video, arbitrary tokens, duplicate fields,
/// lossy rescaling or implicit identity inference. Unknown fields fail closed.
public enum SAMImageSegmentation {
    public static func decode(_ text: String, width: Int, height: Int,
                              deadline: ContinuousClock.Instant) throws -> [SAMImageDetection] {
        try SAMOneBitMask.check(deadline)
        guard (1...1024).contains(width),(1...1024).contains(height),text.utf8.count <= 196_608 else { throw SAMDecodeError.resourceLimit }
        guard text.utf8.allSatisfy({ $0 < 128 }) else { throw SAMDecodeError.invalidGeometry }
        let line = text.trimmingCharacters(in:.whitespacesAndNewlines)
        if line.isEmpty { return [] }
        guard line.hasPrefix("<0f>"),!line.contains("\n"),!line.contains("\r") else { throw SAMDecodeError.invalidGeometry }
        var cursor = line.index(line.startIndex,offsetBy:4),results: [SAMImageDetection] = [],ids = Set<String>(),totalLocalArea = 0
        func integer(_ value: String?) throws -> Int {
            guard let value,!value.isEmpty,value.utf8.count <= 10,value.utf8.allSatisfy({ (48...57).contains($0) }),let n = Int(value) else { throw SAMDecodeError.invalidGeometry };return n
        }
        func confidence(_ fields: [String:String]) throws -> Confidence? {
            guard let value = fields["c"] else { return nil }
            guard value.utf8.count <= 32,value.range(of:#"^-?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#,options:.regularExpression) != nil,
                  let number = Double(value),let result = try? Confidence(number) else { throw SAMDecodeError.invalidGeometry }
            return result
        }
        func token() throws -> (String,[String:String]) {
            guard line[cursor...].hasPrefix("<|"),let end = line.range(of:"|>",range:cursor..<line.endIndex) else { throw SAMDecodeError.invalidGeometry }
            let start = line.index(cursor,offsetBy:2),body = line[start..<end.lowerBound]
            cursor = end.upperBound
            let pieces = body.split(separator:";",omittingEmptySubsequences:false)
            guard let name = pieces.first,["box","mask"].contains(String(name)),pieces.count <= 9 else { throw SAMDecodeError.invalidGeometry }
            var fields: [String:String] = [:]
            for part in pieces.dropFirst() {
                let pair = part.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false)
                guard pair.count == 2 else { throw SAMDecodeError.invalidGeometry }
                let key = pair[0].trimmingCharacters(in:.whitespaces),value = pair[1].trimmingCharacters(in:.whitespaces)
                guard fields.updateValue(value,forKey:key) == nil else { throw SAMDecodeError.invalidGeometry }
            }
            return (String(name),fields)
        }
        while cursor < line.endIndex {
            try SAMOneBitMask.check(deadline)
            guard results.count < 16,(results.count+1)*width*height <= 4_194_304 else { throw SAMDecodeError.resourceLimit }
            if line[cursor] == "," { cursor = line.index(after:cursor) }
            let start = cursor
            while cursor < line.endIndex,line[cursor] >= "0",line[cursor] <= "9" { cursor = line.index(after:cursor) }
            let id = String(line[start..<cursor])
            guard (1...64).contains(id.utf8.count),ids.insert(id).inserted else { throw SAMDecodeError.invalidGeometry }
            let first = try token(),second = try token()
            guard first.0 != second.0 else { throw SAMDecodeError.invalidGeometry }
            let boxFields = first.0 == "box" ? first.1 : second.1,maskFields = first.0 == "mask" ? first.1 : second.1
            guard Set(boxFields.keys).isSubset(of:["x1","y1","x2","y2","w","h","c"]),
                  Set(maskFields.keys).isSubset(of:["x","y","data","c"]),
                  try integer(boxFields["w"]) == width,try integer(boxFields["h"]) == height,
                  try integer(maskFields["x"]) == 0,try integer(maskFields["y"]) == 0 else { throw SAMDecodeError.invalidGeometry }
            let x = try integer(boxFields["x1"]),y = try integer(boxFields["y1"])
            let x2 = try integer(boxFields["x2"]),y2 = try integer(boxFields["y2"])
            guard x <= x2,y <= y2,x2 < width,y2 < height else { throw SAMDecodeError.invalidGeometry }
            let box = try PixelBox(x:x,y:y,width:x2-x+1,height:y2-y+1)
            guard let data = maskFields["data"] else { throw SAMDecodeError.invalidGeometry }
            let parts = data.split(separator:",",omittingEmptySubsequences:false)
            guard parts.count == 3 else { throw SAMDecodeError.invalidGeometry }
            let rows = try integer(String(parts[0])),columns = try integer(String(parts[1]))
            guard rows == box.height,columns == box.width else { throw SAMDecodeError.invalidGeometry }
            totalLocalArea += rows*columns
            guard totalLocalArea <= 1_048_576 else { throw SAMDecodeError.resourceLimit }
            let boxScore = try confidence(boxFields),maskScore = try confidence(maskFields)
            let local = try SAMOneBitMask.decode(String(parts[2]),width:columns,height:rows,deadline:deadline)
            guard local.contains(1) else { throw SAMDecodeError.invalidGeometry }
            var full = Data(repeating:0,count:width*height)
            for row in 0..<rows {
                try SAMOneBitMask.check(deadline)
                let start = (y+row)*width+x
                full.replaceSubrange(start..<start+columns,with:local[row*columns..<(row+1)*columns])
            }
            results.append(SAMImageDetection(localID:id,box:box,mask:try BinaryMask(width:width,height:height,pixels:full),boxConfidence:boxScore,maskConfidence:maskScore))
        }
        guard !results.isEmpty else { throw SAMDecodeError.invalidGeometry };return results
    }
}
