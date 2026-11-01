import Foundation
import SquidraMeta
import SquidraPostgres
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Explicit local demo profile, never a fallback for a missing live provider.
struct SyntheticImportConfiguration: Sendable {
    enum Invalid: Error { case configuration, fixture }
    let policy: SyntheticScenePolicy
    let model: SyntheticVisionModel
    static func read(environment: [String:String], actorID: UUID) throws -> Self? {
        let keys = ["SQUIDRA_SYNTHETIC_IMPORT", "SQUIDRA_SYNTHETIC_FIXTURE", "SQUIDRA_SYNTHETIC_CAMERA_ID", "SQUIDRA_SYNTHETIC_SCENE_ID", "SQUIDRA_SYNTHETIC_COORDINATE_FRAME_ID"]
        guard keys.contains(where:{environment[$0] != nil}) else { return nil }
        guard keys.allSatisfy({environment[$0] != nil}), environment[keys[0]] == "1",
              let camera = UUID(uuidString:environment[keys[2]]!),let scene = UUID(uuidString:environment[keys[3]]!),let frame = UUID(uuidString:environment[keys[4]]!) else { throw Invalid.configuration }
        let path = environment[keys[1]]!
        guard path.hasPrefix("/"),!path.contains("\0"),path.utf8.count <= 4096 else { throw Invalid.fixture }
        let fd = open(path,O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Invalid.fixture }
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true); defer { try? handle.close() }
        var info = stat()
        guard fstat(fd,&info) == 0,(info.st_mode & S_IFMT) == S_IFREG,info.st_size > 0,info.st_size <= 32768,
              let data = try handle.read(upToCount:32769),data.count == Int(info.st_size),data.count <= 32768 else { throw Invalid.fixture }
        return try Self(policy:SyntheticScenePolicy(actorID:actorID,cameraID:camera,locationID:scene,coordinateFrameID:frame),model:SyntheticVisionModel(fixtureData:data))
    }
}
