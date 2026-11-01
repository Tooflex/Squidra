import Foundation
import SquidraSecurity
import XCTest

final class CredentialProviderTests: XCTestCase, @unchecked Sendable {
    func testRotationRevocationAndStaleVersion() async throws {
        let first = try BearerCredential(String(repeating: "a", count: 64))
        let second = try BearerCredential(String(repeating: "b", count: 64))
        let reference = CredentialReference()
        let provider = RotatingCredentialProvider(reference: reference, value: first)
        let old = try await provider.credential(for: reference, deadline: .now.advanced(by: .seconds(1)))
        XCTAssertTrue(old.matches("Bearer " + String(repeating: "a", count: 64)))
        let version = try await provider.rotate(second, reference: reference, expectedVersion: 0)
        XCTAssertEqual(version, 1)
        let current = try await provider.credential(for: reference, deadline: .now.advanced(by: .seconds(1)))
        XCTAssertFalse(current.matches("Bearer " + String(repeating: "a", count: 64)))
        XCTAssertTrue(current.matches("Bearer " + String(repeating: "b", count: 64)))
        do { _ = try await provider.rotate(first, reference: reference, expectedVersion: 0); XCTFail("Stale rotation succeeded") }
        catch { XCTAssertEqual(error as? CredentialError, .conflict) }
        _ = try await provider.rotate(nil, reference: reference, expectedVersion: 1)
        do { _ = try await provider.credential(for: reference, deadline: .now.advanced(by: .seconds(1))); XCTFail("Revoked credential resolved") }
        catch { XCTAssertEqual(error as? CredentialError, .unavailable) }
    }

    func testForeignReferenceDeadlineAndCancellationFailClosed() async throws {
        let reference = CredentialReference(), value = try BearerCredential(String(repeating: "c", count: 64))
        let provider = RotatingCredentialProvider(reference: reference, value: value)
        do { _ = try await provider.credential(for: CredentialReference(), deadline: .now.advanced(by: .seconds(1))); XCTFail("Foreign reference resolved") }
        catch { XCTAssertEqual(error as? CredentialError, .unavailable) }
        do { _ = try await provider.credential(for: reference, deadline: .now.advanced(by: .seconds(-1))); XCTFail("Expired lookup resolved") }
        catch { XCTAssertEqual(error as? CredentialError, .deadlineExceeded) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await provider.credential(for: reference, deadline: .now.advanced(by: .seconds(1)))
        }
        do { _ = try await task.value; XCTFail("Cancelled lookup resolved") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testValidationAndDiagnosticRedaction() throws {
        let canary = String(repeating: "deadbeef", count: 8)
        let value = try BearerCredential(canary)
        let provider = RotatingCredentialProvider(reference: CredentialReference(), value: value)
        for invalid in ["", String(repeating: "z", count: 64), canary + "a", String(canary.dropLast())] {
            XCTAssertThrowsError(try BearerCredential(invalid))
        }
        for invalid in [nil, "bearer " + canary, "Bearer " + canary + "x", "Bearer " + String(repeating: "0", count: 64)] {
            XCTAssertFalse(value.matches(invalid))
        }
        XCTAssertFalse(String(reflecting: value).contains(canary))
        XCTAssertFalse(String(describing: value).contains(canary))
        XCTAssertFalse(String(reflecting: provider).contains(canary))
    }
}
