import Foundation
import SquidraDomain
import SquidraMeta
import SquidraPostgres

/// Explicit dated cloud qualification; never selected by credential presence.
struct SAMImportConfiguration: Sendable {
    enum Invalid: Error { case configuration, consent, expired, budget }
    let policy: FrameScenePolicy
    let model: MetaSAMVisionModel
    let admission: MetaSAMCloudAdmission

    static func read(environment: [String:String], actorID: UUID, clock: any SquidraDomain.Clock,
                     transportFactory: (String) throws -> any MetaResponsesTransport = { try MetaHTTPSResponseTransport(apiKey:$0) }) throws -> Self? {
        let keys = ["SQUIDRA_SAM_IMPORT", "SQUIDRA_SAM_CONCEPT", "SQUIDRA_SAM_CAMERA_ID", "SQUIDRA_SAM_SCENE_ID", "SQUIDRA_SAM_COORDINATE_FRAME_ID", "SQUIDRA_SAM_CLOUD_MEDIA_CONSENT"]
        guard keys.contains(where:{environment[$0] != nil}) else { return nil }
        guard keys.allSatisfy({environment[$0] != nil}),environment[keys[0]] == "1",
              let camera = UUID(uuidString:environment[keys[2]]!),let scene = UUID(uuidString:environment[keys[3]]!),
              let frame = UUID(uuidString:environment[keys[4]]!) else { throw Invalid.configuration }
        guard environment[keys[5]] == "1" else { throw Invalid.consent }
        guard try clock.now().secondsSince1970+30 < MetaFileAttemptBudget.validUntilSeconds else { throw Invalid.expired }
        guard let path = environment["SQUIDRA_META_BUDGET_DIRECTORY"],path.hasPrefix("/"),!path.contains("\0"),path.utf8.count <= 4096 else { throw Invalid.budget }
        let key = try MetaCredentialConfiguration.read(environment:environment)
        let model = try MetaSAMVisionModel(concept:environment[keys[1]]!,transport:transportFactory(key))
        let budget = try MetaFileAttemptBudget(directory:URL(fileURLWithPath:path,isDirectory:true),clock:clock)
        return try Self(policy:FrameScenePolicy(actorID:actorID,cameraID:camera,locationID:scene,coordinateFrameID:frame,cloudIdentity:model.identity),
                        model:model,admission:MetaSAMCloudAdmission(budget:budget))
    }
}
