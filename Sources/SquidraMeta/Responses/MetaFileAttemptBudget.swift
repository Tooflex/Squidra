import Foundation
import CoreFoundation
import Crypto
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
public protocol MetaSAMAttemptBudget: Sendable {
    /// Reserve one image attempt durably against the same global Meta/SAM cap.
    func reserveSAM(attemptID: UUID, frameID: UUID, deadline: ContinuousClock.Instant) async throws
}
/// Dated, opt-in qualification envelope shared with Scripts/test-meta-live.py.
/// Requires existing state; never initializes, resets or refunds the test budget.
/// Use a local filesystem with reliable flock, atomic rename and fsync semantics.
public struct MetaFileAttemptBudget: MetaAttemptBudget, MetaSAMAttemptBudget {
    public static let validUntilSeconds: Double = 1_793_577_600
    public static let maximumReservationMicroUSD: Int64 = 11_172_000 // 10 EUR × 1.1172
    public static let sparkPolicyID = "spark-standard-2026-11-03"
    public static let sparkValidUntilSeconds: Double = 1_793_836_800
    public static let sparkMaximumCostMicroUSD: Int64 = 1_500_000
    private let directory: URL
    private let clock: any SquidraDomain.Clock
    public init(directory: URL, clock: any SquidraDomain.Clock) throws {
        guard directory.isFileURL,directory.path.hasPrefix("/"),!directory.path.contains("\0") else { throw MetaBudgetError.unsafePath }
        self.directory = directory;self.clock = clock
    }
    @concurrent
    public func reserve(attemptID: UUID, requestID: UUID, model: MetaTextModel,
                        maximumCostMicroUSD: Int64, deadline: ContinuousClock.Instant) async throws {
        try reserveRecord(attemptID:attemptID,model:model.rawValue,maximumCostMicroUSD:maximumCostMicroUSD,deadline:deadline)
    }
    @concurrent
    public func reserveSAM(attemptID: UUID, frameID: UUID, deadline: ContinuousClock.Instant) async throws {
        try reserveRecord(attemptID:attemptID,model:"sam-3.1",maximumCostMicroUSD:10_000_000,deadline:deadline)
    }
    private func reserveRecord(attemptID: UUID, model: String, maximumCostMicroUSD: Int64, deadline: ContinuousClock.Instant) throws {
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
        let state = try validatedState(ledger)
        var attempts = state.attempts
        guard try clock.now().secondsSince1970 < state.expiry else { throw MetaBudgetError.expired }
        guard maximumCostMicroUSD <= state.maximumCost,
              !state.sparkOnly || model == MetaTextModel.spark.rawValue else { throw MetaBudgetError.invalidReservation }
        guard state.used + state.reservation <= 10000 else { throw ModelRoutingError.budgetExceeded }
        let id = attemptID.uuidString.lowercased()
        guard !state.ids.contains(id) else { throw MetaBudgetError.invalidReservation }
        // Keep prior history intact. Correlation is intentionally omitted;
        // no question, provider ID, credential or private world data is persisted.
        attempts.append(["id":id,"model":model,"reservedEURCents":state.reservation,"status":"reserved","report":NSNull()])
        ledger["attempts"] = attempts
        let output = try JSONSerialization.data(withJSONObject:ledger,options:[.sortedKeys,.prettyPrinted,.withoutEscapingSlashes])
        guard output.count <= 262_144 else { throw MetaBudgetError.invalidLedger }
        try check(deadline,expiry:state.expiry)
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
        try check(deadline,expiry:state.expiry)
        guard renameat(parent,name,parent,"live-budget.json") == 0,fsync(parent) == 0 else { throw MetaBudgetError.unavailable }
        // Cancellation/expiry after commit retains the reservation but forbids dispatch.
        try check(deadline,expiry:state.expiry)
    }
    private func check(_ deadline: ContinuousClock.Instant, expiry: Double? = nil) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw ModelRoutingError.deadlineExceeded }
        if let expiry { guard try clock.now().secondsSince1970 < expiry else { throw MetaBudgetError.expired } }
    }
    private func validateFile(_ fd: Int32, maximum: Int64?) throws {
        var info = stat()
        guard fstat(fd,&info) == 0,info.st_mode & S_IFMT == S_IFREG,info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o600,info.st_nlink == 1 else { throw MetaBudgetError.unsafePath }
        if let maximum { guard info.st_size > 0,info.st_size <= maximum else { throw MetaBudgetError.invalidLedger } }
    }
    private struct State {
        let attempts: [[String:Any]]
        let ids: Set<String>
        let used: Int
        let reservation: Int
        let expiry: Double
        let maximumCost: Int64
        let sparkOnly: Bool
    }
    private func validatedState(_ ledger: [String:Any]) throws -> State {
        if (ledger["schemaVersion"] as? NSNumber)?.stringValue == "1" {
            let attempts = try validatedAttempts(ledger)
            return State(attempts:attempts,ids:Set(attempts.compactMap{$0["id"] as? String}),used:attempts.count*1000,
                         reservation:1000,expiry:Self.validUntilSeconds,maximumCost:Self.maximumReservationMicroUSD,sparkOnly:false)
        }
        guard Set(ledger.keys) == ["schemaVersion","authorizedEURCents","policyID","fx","validUntil","history","attempts"],
              integer(ledger["schemaVersion"],equals:2),integer(ledger["authorizedEURCents"],equals:10000),
              ledger["policyID"] as? String == Self.sparkPolicyID,
              ledger["fx"] as? [String:String] == ["usdPerEUR":"1.1179","date":"2026-11-03","source":"ECB"],
              ledger["validUntil"] as? String == "2026-11-05T00:00:00+00:00",
              let history = ledger["history"] as? [String:String],Set(history.keys) == ["base64","sha256"],
              let encoded = history["base64"],let raw = Data(base64Encoded:encoded),raw.count <= 262_144,
              raw.base64EncodedString() == encoded,
              SHA256.hash(data:raw).map({String(format:"%02x",$0)}).joined() == history["sha256"],
              let document = try? JSONDocument(raw,maximumBytes:262_144),!document.containsNUL,
              let legacy = try? JSONSerialization.jsonObject(with:document.bytes) as? [String:Any],
              let attempts = ledger["attempts"] as? [[String:Any]],attempts.count <= 40 else { throw MetaBudgetError.invalidLedger }
        let old = try validatedAttempts(legacy)
        var ids = Set(old.compactMap{$0["id"] as? String})
        for item in attempts {
            guard Set(item.keys) == ["id","model","reservedEURCents","status","report"],
                  let id = item["id"] as? String,UUID(uuidString:id)?.uuidString.lowercased() == id,ids.insert(id).inserted,
                  item["model"] as? String == MetaTextModel.spark.rawValue,integer(item["reservedEURCents"],equals:250),
                  let status = item["status"] as? String,["reserved","passed","failed","interrupted"].contains(status),
                  item["report"] is NSNull || item["report"] is [String:Any] else { throw MetaBudgetError.invalidLedger }
        }
        let used = old.count*1000 + attempts.count*250
        guard used <= 10000 else { throw MetaBudgetError.invalidLedger }
        return State(attempts:attempts,ids:ids,used:used,reservation:250,expiry:Self.sparkValidUntilSeconds,
                     maximumCost:Self.sparkMaximumCostMicroUSD,sparkOnly:true)
    }
    private func integer(_ value: Any?, equals expected: Int) -> Bool {
        guard let number = value as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),!["f","d"].contains(String(cString:number.objCType)) else { return false }
        return number.stringValue == String(expected)
    }
    private func validatedAttempts(_ ledger: [String:Any]) throws -> [[String:Any]] {
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
