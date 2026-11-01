import Foundation
import SquidraDomain
import SquidraTemporal
import SquidraSpatial
import SquidraPerception

struct Dataset: Decodable { let cases: [Case] }
// No expected labels are decoded by the production runner.
struct Case: Decodable { let id: String, kind: String, input: Input }
struct Input: Decodable {
    let relation: String?
    let a: [Double]?, b: [Double]?, lower: [Double]?, upper: [Double]?
    let error: Double?, calibrated: Bool?, confirmed: Bool?
    let positions: [Double?]?, times: [Double]?, ambiguous: [Int]?, frameChangeAt: Int?
}
struct Prediction: Encodable { let id: String, prediction: Bool }
enum Failure: Error { case invalid }
@main struct EvalRunner {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw Failure.invalid }
        let dataset = try JSONDecoder().decode(Dataset.self,from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let predictions = try dataset.cases.map { Prediction(id: $0.id,prediction: try predict($0)) }
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.prettyPrinted]
        try encoder.encode(predictions).write(to: URL(fileURLWithPath: CommandLine.arguments[2]),options: .atomic)
    }
    static func predict(_ row: Case) throws -> Bool {
        let i = row.input
        if row.kind == "temporal" {
            guard let a = i.a,let b = i.b,a.count == 2,b.count == 2 else { throw Failure.invalid }
            let lhs = try InstantInterval(start: UTCInstant(secondsSince1970: a[0]),end: UTCInstant(secondsSince1970: a[1]))
            let rhs = try InstantInterval(start: UTCInstant(secondsSince1970: b[0]),end: UTCInstant(secondsSince1970: b[1]))
            switch i.relation { case "before": return IntervalAlgebra.before(lhs,rhs);case "overlaps": return IntervalAlgebra.overlaps(lhs,rhs);case "during": return IntervalAlgebra.during(lhs,rhs);default: throw Failure.invalid }
        }
        let actor = UUID(),entity = UUID(),frameID = UUID(),camera = UUID(),calibrationID = UUID()
        func frame(_ changed: Bool = false) throws -> SpatialCoordinateFrame {
            try SpatialCoordinateFrame(actorID: actor,id: frameID,up: .positiveZ,calibration: i.calibrated == false ? nil : SpatialCalibration(id: calibrationID,version: changed ? "2" : "1",maximumErrorMeters: 0))
        }
        func observation(entity: UUID,time: Double,lower: [Double],upper: [Double],confirmed: Bool = true) throws -> SpatialObservation {
            let instant = try UTCInstant(secondsSince1970: time)
            return try SpatialObservation(actorID: actor,entityID: entity,coordinateFrameID: frameID,
                geometry: .calibrated3D(SpatialBox3D(lower: lower,upper: upper,maximumErrorMeters: i.error ?? 0)),association: confirmed ? .confirmed : .candidate,
                validity: SpatialValidity(from: instant,to: nil),source: SpatialSource(observationID: UUID(),cameraID: camera,imageFrameID: UUID(),modelID: "authored-benchmark",modelVersion: "1",
                    times: ObservationTimestamps(occurredAt: nil,observedAt: instant,recordedAt: instant,timeZone: IANATimeZone(identifier: "Etc/UTC")),confidence: Confidence(0.8)))
        }
        if row.kind == "spatial" {
            guard let lower = i.lower,let upper = i.upper,let name = i.relation,let predicate = SpatialPredicate(rawValue: name) else { throw Failure.invalid }
            let a = try observation(entity: entity,time: 0,lower: lower,upper: upper,confirmed: i.confirmed ?? true)
            let b = try observation(entity: UUID(),time: 0,lower: [0,0,0],upper: [1,1,1])
            return try CalibratedRelationExtractor(actorID: actor,policy: SpatialRelationPolicy(id: UUID())).evaluate(subject: a,object: b,frame: frame()).relations.contains { $0.predicate == predicate }
        }
        guard row.kind == "movement",let positions = i.positions else { throw Failure.invalid }
        let samples = try positions.enumerated().map { n,x -> MovementSample in
            let time = i.times?[n] ?? Double(n)
            let o = try x.map { try observation(entity: entity,time: time,lower: [$0,0,0],upper: [$0+0.1,0.1,0.1],confirmed: !(i.ambiguous ?? []).contains(n)) }
            return try MovementSample(observedAt: UTCInstant(secondsSince1970: time),observation: o,frame: frame(i.frameChangeAt.map { n >= $0 } ?? false))
        }
        let detector = try ConfirmedMovementDetector(actorID: actor,entityID: entity,epochID: UUID(),entityType: "cup",policy: MovementPolicy(id: UUID(),thresholdsByType: ["cup": MovementThreshold(minimumDisplacementMeters: 0.1)]))
        return try !detector.evaluate(samples).events.isEmpty
    }
}
