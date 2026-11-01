import Foundation
import PostgresNIO
import SquidraAgentRuntime
import SquidraCognition
import SquidraDomain
import SquidraPostgres
import SquidraSecurity
import SquidraTemporal
import SquidraTools
import SquidraWorld

/// Scripted proposals, not inference. The production runtime must validate every
/// proposal and obtain its evidence from the real PostgreSQL projection.
private actor HistoricalScriptedModel: LanguageModel {
    nonisolated let descriptor = ModelDescriptor(id:"fixture.historical-demo",modelVersion:"1",location:.local,capabilities:[.text,.structuredOutput],maximumCostMicroUSD:0)
    let subject: UUID, frame: UUID, location: UUID?, citation: UUID?
    let validAt: String, knownAt: String
    private(set) var calls = 0
    init(subject:UUID,frame:UUID,location:UUID?,citation:UUID?,validAt:String,knownAt:String) {
        self.subject=subject;self.frame=frame;self.location=location;self.citation=citation;self.validAt=validAt;self.knownAt=knownAt
    }
    func generate(_ request:ModelRequest) async throws -> ModelResponse {
        calls += 1
        let object:[String:Any]
        if calls==1 {
            object=["schemaVersion":"1","tool":"world.get_entity_location@1.0.0","arguments":["schemaVersion":"1","entityId":subject.uuidString,"validAt":validAt,"knownAt":knownAt]]
        } else {
            try require(calls==2)
            let claim:[String:Any]
            if let location,let citation {
                claim=["kind":"location","subjectId":subject.uuidString,"locationId":location.uuidString,"frameId":frame.uuidString,"citations":[citation.uuidString]]
            } else { claim=["kind":"unknown","subjectId":subject.uuidString,"citations":[]] }
            object=["schemaVersion":"1","claims":[claim]]
        }
        return ModelResponse(requestID:request.id,modelID:descriptor.id,modelVersion:descriptor.modelVersion,text:String(decoding:try JSONSerialization.data(withJSONObject:object),as:UTF8.self),outputTokens:64,costMicroUSD:0)
    }
}

private actor CountedLocationQuery: WorldStateQuery {
    let source: PostgresLocationProjection
    private(set) var reads = 0
    init(_ source: PostgresLocationProjection) { self.source=source }
    func state(actorID: UUID, subjectID: UUID, validAt: UTCInstant, knownAt: UTCInstant, deadline: ContinuousClock.Instant) async throws -> WorldStateSnapshot {
        reads += 1
        return try await source.state(actorID:actorID,subjectID:subjectID,validAt:validAt,knownAt:knownAt,deadline:deadline)
    }
}

extension DemoFixture {
    static func fakeModelDemo(client:PostgresClient,identity:Identity,scenario:Scenario,path:URL) async throws {
        let clock=SystemClock(timeZone:try IANATimeZone(identifier:"Etc/UTC"))
        let store=PostgresRunStore(client:client)
        let projection=PostgresLocationProjection(actorID:identity.actor,client:client)

        let cases:[(String,UUID,UUID?,UUID?,String,String)]=[
            ("mondayEarly",identity.subject,identity.desk,identity.events[0],scenario.monday,scenario.tuesday),
            ("mondayCorrected",identity.subject,identity.drawer,identity.events[2],scenario.monday,scenario.wednesday),
            ("tuesday",identity.subject,identity.shelf,identity.events[1],scenario.tuesday,scenario.wednesday),
            ("unknown",identity.desk,nil,nil,scenario.monday,scenario.wednesday),
            ("fabricatedCitation",identity.subject,identity.desk,UUID(),scenario.monday,scenario.tuesday),
            ("denied",identity.subject,identity.desk,identity.events[0],scenario.monday,scenario.tuesday)]
        var results:[[String:Any]]=[]
        for (name,subject,location,citation,valid,known) in cases {
            let model=HistoricalScriptedModel(subject:subject,frame:identity.frame,location:location,citation:citation,validAt:valid,knownAt:known)
            let query=CountedLocationQuery(projection)
            let registration=try WorldLocationTool(world:query).registration()
            let permission=HostActionPermission(actorID:identity.actor,tool:registration.definition.id,capability:registration.definition.capability,targets:["entity:"+subject.uuidString.lowercased()],scope:["world:read"],expiresAt:.now.advanced(by:.seconds(60)))
            let policy:any PolicyEngine = name=="denied" ? DenyAllActionPolicy() : HostActionPolicy(permissions:[permission])
            let engine=try ReadRunEngine(router:ModelRouter(models:[model],clock:clock),gateway:ActionGateway(tools:[registration],policy:policy),store:store,clock:clock,freshness:AnswerFreshnessPolicy(maximumObservationAgeSeconds:86400,minimumCurrentConfidence:Confidence(0.5)))
            let request=try ReadRunRequest(actorID:identity.actor,question:"Where was Arduino at \(valid), according to knowledge at \(known)?",planningScope:ReadPlanningScope(entities:[PlanningEntity(id:subject,label:name=="unknown" ? "Unlocated fixture entity" : "Arduino")]),effectiveToolScope:["world:read"],intent:.historical,modelOptions:ReadPlanningOptions(deadline:UTCInstant(secondsSince1970:clock.now().secondsSince1970+30)))
            do {
                let result=try await engine.execute(request)
                try require(name != "fabricatedCitation" && name != "denied")
                try require(result.snapshot.state == .completed && result.snapshot.calls==1 && result.snapshot.traceID==request.traceID)
                try require(result.answer.requestId==request.requestID && result.answer.actorId==identity.actor)
                try require(await model.calls==2 && result.reservedModelCostUpperBoundMicroUSD==0)
                if let location,let citation {
                    try require(result.answer.status == .grounded && result.answer.claims.count==1)
                    try require(result.answer.claims[0].locationId==location && result.answer.claims[0].citationIds==[citation])
                    try require(result.answer.evidence.count==1 && result.answer.evidence[0].id==citation && result.answer.evidence[0].confidence==0.8)
                } else { try require(result.answer.status == .unknown && result.answer.evidence.isEmpty) }
                try require(await query.reads==1)
                let persisted=try await store.load(actorID:identity.actor,runID:request.runID,deadline:.now.advanced(by:.seconds(4)))
                try require(persisted.state == .completed && persisted.version==result.snapshot.version)
                results.append(["case":name,"runID":request.runID.uuidString,"traceID":request.traceID.uuidString,"requestID":request.requestID.uuidString,"modelCalls":await model.calls,"reservedToolAttempts":result.snapshot.calls,"worldReads":await query.reads,"answer":try JSONSerialization.jsonObject(with:JSONEncoder().encode(result.answer))])
            } catch let failure as ReadRunFailure {
                let expected:ReadRunFailureCode = name=="denied" ? .denied : .invalidAnswer
                try require(["denied","fabricatedCitation"].contains(name) && failure.code==expected && failure.runID==request.runID && failure.traceID==request.traceID)
                let persisted=try await store.load(actorID:identity.actor,runID:request.runID,deadline:.now.advanced(by:.seconds(4)))
                try require(persisted.state == .failed && persisted.calls==1)
                try require(await model.calls==(name=="denied" ? 1:2))
                try require(await query.reads==(name=="denied" ? 0:1))
                results.append(["case":name,"runID":request.runID.uuidString,"traceID":request.traceID.uuidString,"failure":failure.code.rawValue,"modelCalls":await model.calls,"reservedToolAttempts":persisted.calls,"worldReads":await query.reads])
            }
        }
        let report:[String:Any]=["schemaVersion":1,"modelMode":"scripted-fixture","modelID":"fixture.historical-demo","modelVersion":"1","realModelExecuted":false,"fakeModelExecuted":true,"inferenceQualityMeasured":false,"providerCalls":0,"cases":results]
        try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:path,options:.atomic)
    }
}

private actor ToolFreeTextFixture: LanguageModel {
    nonisolated let descriptor=ModelDescriptor(id:"fixture.tool-free-latency",modelVersion:"1",location:.local,capabilities:[.text],maximumCostMicroUSD:0)
    private(set) var calls=0
    func generate(_ request:ModelRequest) async throws -> ModelResponse {
        calls += 1
        return ModelResponse(requestID:request.id,modelID:descriptor.id,modelVersion:descriptor.modelVersion,text:"fixture-ok",outputTokens:4,costMicroUSD:0)
    }
}

extension DemoFixture {
    static func latencyDemo(client:PostgresClient,identity:Identity,scenario:Scenario,path:URL) async throws {
        func milliseconds(_ elapsed:Duration) -> Double {
            let value=elapsed.components
            return Double(value.seconds)*1000+Double(value.attoseconds)/1e15
        }
        let clock=SystemClock(timeZone:try IANATimeZone(identifier:"Etc/UTC"))
        let store=PostgresRunStore(client:client)
        let projection=PostgresLocationProjection(actorID:identity.actor,client:client)
        var runtime:[[String:Any]]=[],modelOnly:[[String:Any]]=[]
        for index in 0..<33 {
            let model=HistoricalScriptedModel(subject:identity.subject,frame:identity.frame,location:identity.desk,citation:identity.events[0],validAt:scenario.monday,knownAt:scenario.tuesday)
            let query=CountedLocationQuery(projection)
            let registration=try WorldLocationTool(world:query).registration()
            let permission=HostActionPermission(actorID:identity.actor,tool:registration.definition.id,capability:registration.definition.capability,targets:["entity:"+identity.subject.uuidString.lowercased()],scope:["world:read"],expiresAt:.now.advanced(by:.seconds(60)))
            let engine=try ReadRunEngine(router:ModelRouter(models:[model],clock:clock),gateway:ActionGateway(tools:[registration],policy:HostActionPolicy(permissions:[permission])),store:store,clock:clock,freshness:AnswerFreshnessPolicy(maximumObservationAgeSeconds:86400,minimumCurrentConfidence:Confidence(0.5)))
            let request=try ReadRunRequest(actorID:identity.actor,question:"Where was Arduino on Monday, as known on Tuesday?",planningScope:ReadPlanningScope(entities:[PlanningEntity(id:identity.subject,label:"Arduino")]),effectiveToolScope:["world:read"],intent:.historical,modelOptions:ReadPlanningOptions(deadline:UTCInstant(secondsSince1970:clock.now().secondsSince1970+30)))
            let start=ContinuousClock.now
            let result=try await engine.execute(request)
            let elapsed=milliseconds(start.duration(to:.now))
            try require(result.snapshot.state == .completed && result.snapshot.calls==1 && result.snapshot.traceID==request.traceID)
            try require(result.answer.status == .grounded && result.answer.requestId==request.requestID && result.answer.actorId==identity.actor)
            try require(result.answer.claims.count==1 && result.answer.claims[0].locationId==identity.desk && result.answer.claims[0].citationIds==[identity.events[0]])
            try require(result.answer.evidence.count==1 && result.answer.evidence[0].confidence==0.8)
            try require(await model.calls==2)
            try require(await query.reads==1)
            let saved=try await store.load(actorID:identity.actor,runID:request.runID,deadline:.now.advanced(by:.seconds(4)))
            try require(saved.state == .completed && saved.version==result.snapshot.version)
            runtime.append(["milliseconds":elapsed,"warmup":index<3,"runID":request.runID.uuidString,"modelCalls":2,"worldReads":1,"state":"COMPLETED"])
        }
        let model=ToolFreeTextFixture()
        let router=try ModelRouter(models:[model],clock:clock)
        for index in 0..<33 {
            let request=try ModelRequest(id:UUID(),messages:[ModelMessage(role:.user,content:"Return fixture-ok")],deadline:UTCInstant(secondsSince1970:clock.now().secondsSince1970+30))
            let start=ContinuousClock.now
            let result=try await router.generate(request)
            let elapsed=milliseconds(start.duration(to:.now))
            try require(result.response.requestID==request.id && result.response.text=="fixture-ok" && result.attemptedModelIDs==[model.descriptor.id] && result.reservedCostUpperBoundMicroUSD==0)
            modelOnly.append(["milliseconds":elapsed,"warmup":index<3,"requestID":request.id.uuidString,"modelCalls":1,"worldReads":0])
        }
        try require(await model.calls==33)
        let rows=try await client.query("SELECT version()").collect()
        let version=try rows[0].decode(String.self)
        #if DEBUG
        let configuration="debug"
        #else
        let configuration="release"
        #endif
        let report:[String:Any]=["schemaVersion":1,"mode":"offline-scripted-latency","realModelExecuted":false,"providerCalls":0,"concurrency":1,"measuredCount":30,"warmupCount":3,"buildConfiguration":configuration,"databaseVersion":version,"os":ProcessInfo.processInfo.operatingSystemVersionString,"activeProcessorCount":ProcessInfo.processInfo.activeProcessorCount,"physicalMemoryBytes":ProcessInfo.processInfo.physicalMemory,"runtime":runtime,"toolFreeModelPort":modelOnly]
        try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:path,options:.atomic)
    }
}
