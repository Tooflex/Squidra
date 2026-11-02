import {readFile,writeFile} from 'node:fs/promises';
import {acceptance,consume,freshStream} from '../../web/dist/questions/protocol.js';
import assert from 'node:assert/strict';

if(process.env.SQUIDRA_HISTORICAL_META_LIVE!=='1')throw Error('Explicit live consent required');
const [identityPath,scenarioPath,evidencePath,reportPath]=process.argv.slice(2);
const identity=JSON.parse(await readFile(identityPath,'utf8'));
const scenario=JSON.parse(await readFile(scenarioPath,'utf8'));
const expected=JSON.parse(await readFile(evidencePath,'utf8'));
const origin=process.env.SQUIDRA_DEMO_ORIGIN,token=process.env.SQUIDRA_DEMO_TOKEN;
assert.match(origin,/^http:\/\/127\.0\.0\.1:[0-9]+$/);assert.match(token,/^[a-f0-9]{64}$/);
const report={schemaVersion:1,modelMode:'real-meta',modelID:'muse-spark-1.3',realModelExecuted:null,
 fakeModelExecuted:false,origin:'authored-synthetic-replay',outcome:'failed',harnessOutcome:'unverified',cases:[]};
const same=(a,b)=>a.toLowerCase()===b.toLowerCase();
async function request(path,body,cursor){
 const r=await fetch(origin+path,{method:body?'POST':'GET',redirect:'error',signal:AbortSignal.timeout(25000),
  headers:{Authorization:'Bearer '+token,...(body?{'Content-Type':'application/json'}:{}),...(cursor?{'Last-Event-ID':cursor}:{})},
  body:body?JSON.stringify(body):undefined});
 assert.equal(r.status,body?202:200);return await r.text();
}
try{
 for(const [name,known,location] of [['mondayEarly',scenario.tuesday,identity.desk],['mondayCorrected',scenario.wednesday,identity.drawer]]){
  const question=`Where was entity ${identity.subject} at ${scenario.monday}, according to knowledge at ${known}? Cite the evidence.`;
  // Exactly one POST per question; uncertain admission is never resubmitted.
  const run=acceptance(JSON.parse(await request('/api/v1/runs',{schemaVersion:'1',question,entityId:identity.subject.toLowerCase(),intent:'historical'})));
  const item={case:name,run,question,outcome:'pending'};report.cases.push(item);
  let state=freshStream();const end=Date.now()+180000;
  while(!state.terminal&&Date.now()<end){state=consume(state,await request(run.events,undefined,state.cursor),run,identity.subject);}
  assert.equal(state.terminal,'success');assert(same(state.actor,identity.actor));
  const answer=state.answer,proof=answer.evidence[0],source=expected[name];
  assert.equal(answer.status,'grounded');assert.equal(answer.evidence.length,1);assert.equal(answer.claims.length,1);
  assert(same(proof.id,source.sourceEventID)&&same(proof.locationId,location)&&same(proof.frameId,identity.frame));
  assert.equal(proof.source,source.sourceID);assert.equal(proof.observedAt,source.observedAt);
  assert.equal(proof.recordedAt,source.recordedAt);assert.equal(proof.confidence,source.confidence);
  assert.equal(answer.claims[0].kind,'location');assert(same(answer.claims[0].locationId,location));
  item.answer=answer;item.outcome='passed';
  report.realModelExecuted=true;
 }
 report.outcome='passed';console.log('HISTORICAL_META_VERIFIED');
}catch{throw Error('Historical Meta qualification failed; no retry');}
finally{report.checkedAtUTC=new Date().toISOString();await writeFile(reportPath,JSON.stringify(report,null,2)+'\n',{mode:0o600});}
