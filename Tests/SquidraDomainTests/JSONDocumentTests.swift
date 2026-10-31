import Foundation
import SquidraDomain
import XCTest

final class JSONDocumentTests: XCTestCase {
    func testValidGrammarUnicodeAndRootKinds() throws {
        for (text,kind): (String,JSONDocument.Kind) in [("{}",.object),("[]",.array),("true",.boolean),("false",.boolean),("null",.null),("-1.5e+20",.number),(#""Unicode é 👋 \uD83D\uDC4B""#,.string),(#"{"a":[true,false,null,{},[],0],"b":"\/\\\"\b\f\n\r\t"}"#,.object)] {
            XCTAssertEqual(try JSONDocument(Data(text.utf8)).kind,kind)
        }
    }
    func testExactDecimalUnicodeAndWhitespaceBytesAreRetained() throws {
        let data = Data(" \n{\"integer\":9007199254740993,\"decimal\":1.2300e-100,\"text\":\"e\u{301}\"}\t".utf8)
        let document = try JSONDocument(data);XCTAssertEqual(document.bytes,data)
    }
    func testNULIsDetectedWithoutChangingBytesOrLiteralEscapeText() throws {
        XCTAssertTrue(try JSONDocument(Data(#"{"nul":"\u0000"}"#.utf8)).containsNUL)
        XCTAssertTrue(try JSONDocument(Data(#"{"\u0000":0}"#.utf8)).containsNUL)
        XCTAssertFalse(try JSONDocument(Data(#"{"literal":"\\u0000"}"#.utf8)).containsNUL)
    }
    func testDuplicateDecodedAndCanonicalEquivalentKeysReject() {
        for text in [#"{"a":1,"a":2}"#,#"{"a":1,"\u0061":2}"#,#"{"o":{"x":1,"x":2}}"#,#"{"é":1,"e\u0301":2}"#] {
            XCTAssertThrowsError(try JSONDocument(Data(text.utf8)))
        }
    }
    func testMalformedGrammarAndTrailingTokensReject() {
        for text in ["", " ","{", "[", "{]", "[}","[1,]","{\"a\":1,}","{1:2}","{\"a\" 1}","[1 2]","true false","{}{}","undefined","NaN","Infinity","+1","01","-01",".1","1.","1e","1e+","--1",#""\x00""#,#""\u000z""#,#""\uD800""#,"\"raw\nline\"",#""unterminated"#] {
            XCTAssertThrowsError(try JSONDocument(Data(text.utf8)),text)
        }
    }
    func testInvalidUTF8AndOversizedDocumentsReject() {
        for bytes: [UInt8] in [[34,255,34],[34,192,128,34],[34,237,160,128,34]] {
            XCTAssertThrowsError(try JSONDocument(Data(bytes)))
        }
        XCTAssertThrowsError(try JSONDocument(Data("{}".utf8),maximumBytes:1))
        XCTAssertThrowsError(try JSONDocument(Data("{}".utf8),maximumBytes:0))
        XCTAssertThrowsError(try JSONDocument(Data(repeating:32,count:1_048_577),maximumBytes:1_048_576))
    }
    func testDepthAndNodeLimitsHaveExplicitBoundaries() throws {
        let nested = String(repeating:"[",count:32)+"0"+String(repeating:"]",count:32)
        _ = try JSONDocument(Data(nested.utf8))
        XCTAssertThrowsError(try JSONDocument(Data(("["+nested+"]").utf8)))
        let valid = "["+Array(repeating:"0",count:4_095).joined(separator:",")+"]"
        _ = try JSONDocument(Data(valid.utf8))
        let tooMany = "["+Array(repeating:"0",count:4_096).joined(separator:",")+"]"
        XCTAssertThrowsError(try JSONDocument(Data(tooMany.utf8)))
    }
    func testNumericTokenLimitAndFiniteDoubleEnvelope() throws {
        _ = try JSONDocument(Data(("1."+String(repeating:"1",count:126)).utf8))
        XCTAssertThrowsError(try JSONDocument(Data(("1."+String(repeating:"1",count:127)).utf8)))
        XCTAssertThrowsError(try JSONDocument(Data("1e309".utf8)))
        _ = try JSONDocument(Data("1e308".utf8))
    }
}
