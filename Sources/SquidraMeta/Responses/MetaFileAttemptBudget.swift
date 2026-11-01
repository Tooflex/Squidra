import Foundation
import CoreFoundation
import SquidraCognition
import SquidraDomain
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum MetaBudgetError: Error, Equatable, Sendable {
    case unsafePath, unavailable, busy, invalidLedger, expired, invalidReservation
}
/// Dated, opt-in qualification envelope shared with Scripts/test-meta-live.py.
/// Requires existing state; never initializes, resets or refunds the test budget.
/// Use a local filesystem with reliable flock, atomic rename and fsync semantics.
public struct MetaFileAttemptBudget: MetaAttemptBudget {
    public static let validUntilSeconds: Double = 1_793_577_600
    public static let maximumReservationMicroUSD: Int64 = 11_172_000 // 10 EUR × 1.1172
    private let directory: URL
    private let clock: any SquidraDomain.Clock
    public init(directory: URL, clock: any SquidraDomain.Clock) throws {
        guard directory.isFileURL,directory.path.hasPrefix("/"),!directory.path.contains("\0") else { throw MetaBudgetError.unsafePath }
        self.directory = directory;self.clock = clock
    }
    @concurrent
    public func reserve(attemptID: UUID, requestID: UUID, model: MetaTextModel,
                        maximumCostMicroUSD: Int64, deadline: ContinuousClock.Instant) async throws {
        try check(deadline)
        guard maximumCostMicroUSD > 0,maximumCostMicroUSD <= Self.maximumReservationMicroUSD else { throw MetaBudgetError.invalidReservation }
        let parent = open(directory.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw MetaBudgetError.unsafePath }
        defer { _ = close(parent) }
        var info = stat()
        guard fstat(parent,&info) == 0,info.st_uid == geteuid(),info.st_mode & 0o777 == 0o700 else { throw MetaBudgetError.unsafePath }
        let lock = openat(parent,"live-budget.lock",O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,mode_t(0o600))
        guard lock >= 0 else { throw MetaBudgetError.unsafePath }
        defer { _ = close(lock) }
        try validateFile(lock,maximum:nil)
        guard flock(lock,LOCK_EX | LOCK_NB) == 0 else { throw MetaBudgetError.busy }
        try check(deadline)
        let fd = openat(parent,"live-budget.json",O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw MetaBudgetError.unsafePath }
        defer { _ = close(fd) }
        try validateFile(fd,maximum:262_144)
        var bytes = [UInt8](repeating:0,count:262_145),count = 0
        while count < bytes.count {
            let readCount = bytes.withUnsafeMutableBytes { read(fd,$0.baseAddress!.advanced(by:count),$0.count-count) }
            if readCount < 0,errno == EINTR { continue }
            guard readCount >= 0 else { throw MetaBudgetError.unavailable }
            if readCount == 0 { break };count += readCount
        }
        guard count > 0,count <= 262_144 else { throw MetaBudgetError.invalidLedger }
        let document: JSONDocument
        do { document = try JSONDocument(Data(bytes.prefix(count)),maximumBytes:262_144) }
        catch { throw MetaBudgetError.invalidLedger }
        guard document.kind == .object,!document.containsNUL,
              var ledger = try JSONSerialization.jsonObject(with:document.bytes) as? [String:Any] else { throw MetaBudgetError.invalidLedger }
        var attempts = try validatedAttempts(ledger)
        guard attempts.count < 10 else { throw ModelRoutingError.budgetExceeded }
        let id = attemptID.uuidString.lowercased()
        guard !attempts.contains(where:{ $0["id"] as? String == id }) else { throw MetaBudgetError.invalidReservation }
        // Keep the Python schema unchanged. Correlation is intentionally omitted;
        // no question, provider ID, credential or private world data is persisted.
        attempts.append(["id":id,"model":model.rawValue,"reservedEURCents":1000,"status":"reserved","report":NSNull()])
        ledger["attempts"] = attempts
        let output = try JSONSerialization.data(withJSONObject:ledger,options:[.sortedKeys,.prettyPrinted,.withoutEscapingSlashes])
        guard output.count <= 262_144 else { throw MetaBudgetError.invalidLedger }
        try check(deadline)
        let name = ".budget-"+UUID().uuidString.lowercased()
        let temporary = openat(parent,name,O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC,mode_t(0o600))
        guard temporary >= 0 else { throw MetaBudgetError.unavailable }
        defer { _ = close(temporary);_ = unlinkat(parent,name,0) }
        var offset = 0
        while offset < output.count {
            let written = output.withUnsafeBytes { write(temporary,$0.baseAddress!.advanced(by:offset),$0.count-offset) }
            if written < 0,errno == EINTR { continue }
            guard written > 0 else { throw MetaBudgetError.unavailable };offset += written
        }
        guard fsync(temporary) == 0 else { throw MetaBudgetError.unavailable }
        try check(deadline)
        guard renameat(parent,name,parent,"live-budget.json") == 0,fsync(parent) == 0 else { throw MetaBudgetError.unavailable }
        // Cancellation/expiry after commit retains the reservation but forbids dispatch.
        try check(deadline)
    }
    private func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw ModelRoutingError.deadlineExceeded }
        guard try clock.now().secondsSince1970 < Self.validUntilSeconds else { throw MetaBudgetError.expired }
    }
    private func validateFile(_ fd: Int32, maximum: Int64?) throws {
        var info = stat()
        guard fstat(fd,&info) == 0,info.st_mode & S_IFMT == S_IFREG,info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o600,info.st_nlink == 1 else { throw MetaBudgetError.unsafePath }
        if let maximum { guard info.st_size > 0,info.st_size <= maximum else { throw MetaBudgetError.invalidLedger } }
    }
    private func validatedAttempts(_ ledger: [String:Any]) throws -> [[String:Any]] {
        func integer(_ value: Any?, equals expected: Int) -> Bool {
            guard let number = value as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),!["f","d"].contains(String(cString:number.objCType)) else { return false }
            return number.stringValue == String(expected)
        }
        guard Set(ledger.keys) == ["schemaVersion","authorizedEURCents","reservationEURCents","fx","validUntil","attempts"],
              integer(ledger["schemaVersion"],equals:1),integer(ledger["authorizedEURCents"],equals:10000),integer(ledger["reservationEURCents"],equals:1000),
              ledger["fx"] as? [String:String] == ["usdPerEUR":"1.1172","date":"2026-10-30","source":"ECB"],
              ledger["validUntil"] as? String == "2026-11-02T00:00:00+00:00",
              let attempts = ledger["attempts"] as? [[String:Any]],attempts.count <= 10 else { throw MetaBudgetError.invalidLedger }
        var ids = Set<String>()
        for item in attempts {
            guard Set(item.keys) == ["id","model","reservedEURCents","status","report"],
                  let id = item["id"] as? String,UUID(uuidString:id)?.uuidString.lowercased() == id,ids.insert(id).inserted,
                  let model = item["model"] as? String,["muse-spark-1.3","muse-wonder-1.0","sam-3.1"].contains(model),
                  integer(item["reservedEURCents"],equals:1000),let status = item["status"] as? String,
                  ["reserved","passed","failed","interrupted"].contains(status),
                  item["report"] is NSNull || item["report"] is [String:Any] else { throw MetaBudgetError.invalidLedger }
        }
        return attempts
    }
}
