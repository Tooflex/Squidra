// Authored HTTP fixture for manual assistive-technology checks. Never production.
import http from 'node:http';
import {createHash,randomUUID} from 'node:crypto';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
export const token='a'.repeat(64);
export const id=n=>`10000000-0000-0000-0000-${String(n).padStart(12,'0')}`;
const fixture=JSON.parse(await readFile(new URL('../../../fixtures/providers/vision-synthetic.v1.json',import.meta.url),'utf8'));
export const image=Buffer.from(fixture.frames[0].imageBase64,'base64');
const hash=createHash('sha256').update(image).digest('hex');
const observed='2026-11-01T12:01:02.123456Z',known='2026-11-01T12:01:02.456789Z';
const receipt={schemaVersion:'1',deployment:'synthetic',basis:'inferred',mediaRetained:false,frameId:id(1),cameraId:id(2),locationId:id(3),coordinateFrameId:id(4),modelId:'fixture.vision',modelVersion:'1.0.0',imageSHA256:hash,observedAt:observed,knownAt:known,validityMilliseconds:1000,observationEventId:id(5),entities:[{id:id(6),localId:'Arduino de démonstration',sourceEventId:id(7)}]};
export function createFixture({uiOrigin,textRuns=true}) {
 const origin=new URL(uiOrigin);if(origin.protocol!=='http:'||origin.hostname!=='127.0.0.1'||origin.origin!==uiOrigin)throw Error('Loopback UI origin required');
 const runs=new Map(),approvals=new Map();
 function preview(key){if(!approvals.has(key)){const expired=key===id(2);approvals.set(key,{schemaVersion:'1',id:key,runId:id(21),ledgerId:id(22),decision:expired?'expired':'pending',version:0,digest:'b'.repeat(64),commandFingerprint:'c'.repeat(64),tool:'fixture.send@1.0.0',target:'recipient:authored-only',argumentsJSON:'{"message":"Démonstration locale : aucun envoi réel"}',scope:['message:send'],requestedAt:new Date(Date.now()-120000).toISOString(),expiresAt:new Date(Date.now()+(expired?-60000:600000)).toISOString()});}return approvals.get(key);}
 const server=http.createServer(async(req,res)=>{
  const headers={'Cache-Control':'no-store','Content-Type':'application/json; charset=utf-8','X-Content-Type-Options':'nosniff','Access-Control-Allow-Origin':uiOrigin,'Vary':'Origin'};
  const send=(status,value)=>{res.writeHead(status,headers);res.end(JSON.stringify(value));};
  try {
   if(req.headers.origin!==uiOrigin){send(403,{});return;}
   if(req.method==='OPTIONS'){res.writeHead(204,{...headers,'Access-Control-Allow-Methods':'GET, POST, OPTIONS','Access-Control-Allow-Headers':'authorization, content-type, last-event-id'});res.end();return;}
   if(req.headers.authorization!=='Bearer '+token){send(401,{});return;}
   let body;if(req.method==='POST'){let bytes=0,chunks=[];for await(const chunk of req){bytes+=chunk.length;if(bytes>800000){send(413,{});return;}chunks.push(chunk);}try{body=JSON.parse(Buffer.concat(chunks));}catch{send(400,{});return;}}
   if(req.method==='GET'&&req.url==='/api/v1/run-capabilities'){send(200,textRuns?{schemaVersion:'1',textRuns:true}:{schemaVersion:'1',textRuns:false,limitation:'no_configured_read_host'});return;}
   if(req.method==='GET'&&req.url==='/api/v1/frame-import-capabilities'){send(200,{schemaVersion:'1',deployment:'synthetic',maximumImageBytes:524288,requiresCloudTransferConsent:false});return;}
   if(req.method==='POST'&&req.url==='/api/v1/frames/import'){
    if(body?.schemaVersion!=='1'||body.permitsLocalProcessing!==true||body.imageBase64!==image.toString('base64')){send(422,{});return;}send(201,receipt);return;
   }
   if(req.method==='POST'&&req.url==='/api/v1/runs'){
    if(!textRuns){send(503,{});return;}
    if(body?.schemaVersion!=='1'||body.intent!=='historical'||![id(6),id(99)].includes(body.entityId)||typeof body.question!=='string'||!body.question.trim()||Buffer.byteLength(body.question)>4096||runs.size>=32){send(422,{});return;}
    const runId=randomUUID(),threadId=randomUUID(),requestId=randomUUID(),traceId=randomUUID();const accepted={schemaVersion:'1',runId,threadId,requestId,traceId,status:'/api/v1/runs/'+runId,events:'/api/v1/runs/'+runId+'/events'};
    const unknown=body.entityId===id(99);const answer={schemaVersion:'1',actorId:id(20),requestId,intent:'historical',status:unknown?'unknown':'grounded',text:unknown?'Aucune conclusion étayée.':'Position inférée dans la scène de démonstration.',claims:unknown?[{kind:'unknown',subjectId:body.entityId,basis:'unknown',citationIds:[]}]:[{kind:'location',subjectId:id(6),locationId:id(3),frameId:id(4),basis:'inferred',minimumSourceConfidence:.875,citationIds:[id(7)]}],evidence:unknown?[]:[{schemaVersion:'1',id:id(7),subjectId:id(6),locationId:id(3),frameId:id(4),source:'authored-accessibility-fixture',confidence:.875,basis:'inferred',observedAt:observed,recordedAt:known,timeZone:'Etc/UTC',observationAgeSeconds:1.5,freshness:'fresh'}],uncertainty:unknown?['abstained']:['inferredEvidence']};
    const messageId=randomUUID();const events=[{type:'RUN_STARTED',runId,threadId,protocolVersion:'1.0'},{type:'CUSTOM',name:'squidra.grounded_answer.v1',value:answer},{type:'TEXT_MESSAGE_START',messageId,role:'assistant'},{type:'TEXT_MESSAGE_CONTENT',messageId,delta:answer.text},{type:'TEXT_MESSAGE_END',messageId},{type:'RUN_FINISHED',runId,threadId,outcome:{type:'success'}}].map(e=>({...e,timestamp:1793534400000}));runs.set(runId,events);send(202,accepted);return;
   }
   const eventMatch=req.url?.match(/^\/api\/v1\/runs\/([a-f0-9-]{36})\/events$/);
   if(req.method==='GET'&&eventMatch){const runId=eventMatch[1],events=runs.get(runId);if(!events){send(404,{});return;}let offset=0;if(req.headers['last-event-id']){try{const cursor=JSON.parse(Buffer.from(req.headers['last-event-id'],'base64url'));if(cursor.actorId!==id(20)||cursor.runId!==runId||cursor.schemaVersion!=='1'||!/^\d+$/.test(cursor.afterSequence))throw Error();offset=Number(cursor.afterSequence);if(offset<0||offset>events.length)throw Error();}catch{send(400,{});return;}}
    res.writeHead(200,{...headers,'Content-Type':'text/event-stream; charset=utf-8'});res.end(events.slice(offset).map((event,i)=>'id: '+Buffer.from(JSON.stringify({actorId:id(20),runId,schemaVersion:'1',afterSequence:String(offset+i+1)})).toString('base64url')+'\ndata: '+JSON.stringify(event)+'\n\n').join(''));return;
   }
   const approval=req.url?.match(/^\/api\/v1\/approvals\/(10000000-0000-0000-0000-00000000000[12])(\/decision)?$/);
   if(approval){const value=preview(approval[1]);if(req.method==='GET'&&!approval[2]){send(200,value);return;}if(req.method==='POST'&&approval[2]){if(value.decision!=='pending'||Date.parse(value.expiresAt)<=Date.now()||body?.schemaVersion!=='1'||body.digest!==value.digest||!['approved','denied','withdrawn'].includes(body.decision)){send(409,{});return;}Object.assign(value,{decision:body.decision,version:1,decidedAt:new Date().toISOString()});send(200,value);return;}}
   send(404,{});
  }catch{if(!res.headersSent)send(500,{});else res.end();}
 });
 server.requestTimeout=10000;server.headersTimeout=10000;
 return server;
}

async function main(){
 if(process.env.SQUIDRA_ACCESSIBILITY_FIXTURE!=='1'||process.argv.slice(2).some(x=>x!=='--unavailable'))throw Error('Explicit accessibility fixture opt-in required');
 const ui=spawn(process.execPath,['serve.mjs'],{cwd:new URL('../../',import.meta.url),env:{PATH:process.env.PATH,SQUIDRA_WEB_PORT:'0'},stdio:['ignore','pipe','inherit']});
 let api;const stop=()=>{api?.close();ui.kill('SIGTERM');};process.on('SIGTERM',stop);process.on('SIGINT',stop);
 try {
  const uiOrigin=await new Promise((resolve,reject)=>{let text='';const timeout=setTimeout(()=>{reject(Error('UI startup timed out'));},10000);ui.once('exit',()=>{clearTimeout(timeout);reject(Error('UI exited'));});ui.stdout.on('data',chunk=>{text+=chunk;const found=text.match(/SQUIDRA web listening 127.0.0.1:(\d+)/);if(found){clearTimeout(timeout);resolve('http://127.0.0.1:'+found[1]);}});});
  api=createFixture({uiOrigin,textRuns:!process.argv.includes('--unavailable')});await new Promise(resolve=>api.listen(0,'127.0.0.1',resolve));
  const folder=new URL('../../../.build/accessibility/',import.meta.url);await mkdir(folder,{recursive:true,mode:0o700});const png=new URL('fixture.png',folder);await writeFile(png,image,{mode:0o600});
  console.log(JSON.stringify({mode:'AUTHORED_UI_FIXTURE_NOT_REAL_BACKEND',uiOrigin,apiOrigin:'http://127.0.0.1:'+api.address().port,publicFixtureToken:token,imagePath:fileURLToPath(png),entity:id(6),unknownEntity:id(99),approval:id(1),expiredApproval:id(2),question:'Où était Arduino au '+observed+', selon les informations connues au '+known+' ?'}));
 }catch(error){stop();throw error;}
}
if(process.argv[1]===fileURLToPath(import.meta.url))await main();
