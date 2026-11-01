// Read-only validation of the server's grounded-answer AG-UI subset.
// This is presentation validation; authorization and grounding remain server-owned.
export const object=(v:unknown):Record<string,unknown>=>{if(!v||typeof v!=='object'||Array.isArray(v))throw Error('Réponse invalide.');return v as Record<string,unknown>;};
export const uuid=(v:unknown):v is string=>typeof v==='string'&&/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(v);
export const text=(v:unknown,max:number):v is string=>typeof v==='string'&&new TextEncoder().encode(v).length<=max&&!v.includes('\0');
const same=(a:unknown,b:unknown)=>uuid(a)&&uuid(b)&&a.toLowerCase()===b.toLowerCase();
const date=(v:unknown)=>typeof v==='string'&&/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?Z$/.test(v)&&Number.isFinite(Date.parse(v));
const optional=(v:unknown,test:(v:unknown)=>boolean)=>v===undefined||test(v);
const score=(v:unknown)=>typeof v==='number'&&Number.isFinite(v)&&v>=0&&v<=1;
export type Acceptance={schemaVersion:string;runId:string;threadId:string;requestId:string;traceId:string;status:string;events:string};
export function acceptance(raw:unknown):Acceptance {const p=object(raw);if(p.schemaVersion!=='1'||!['runId','threadId','requestId','traceId'].every(k=>uuid(p[k]))||p.status!=='/api/v1/runs/'+p.runId||p.events!==p.status+'/events')throw Error('Admission du run invalide. Aucun renvoi automatique.');return p as Acceptance;}
export type Evidence={schemaVersion:string;id:string;subjectId:string;locationId:string;frameId:string;source:string;confidence:number;basis:'observed'|'inferred';occurredAt?:string;observedAt:string;recordedAt:string;timeZone:string;observationAgeSeconds?:number;freshness:'fresh'|'stale'|'clock_skew'};
export type Claim={kind:'unknown'|'location'|'change';subjectId:string;locationId?:string;frameId?:string;changeId?:string;basis:string;changeKind?:string;minimumSourceConfidence?:number;citationIds:string[]};
export type Answer={schemaVersion:string;actorId:string;requestId:string;intent:'historical';status:'grounded'|'partial'|'unknown';text:string;claims:Claim[];evidence:Evidence[];uncertainty:string[]};
function answer(raw:unknown,run:Acceptance,actor:string,entity:string):Answer {
 const p=object(raw);if(p.schemaVersion!=='1'||!same(p.actorId,actor)||!same(p.requestId,run.requestId)||p.intent!=='historical'||!['grounded','partial','unknown'].includes(String(p.status))||!text(p.text,65536)||!Array.isArray(p.evidence)||p.evidence.length>256||!Array.isArray(p.claims)||p.claims.length>16||!Array.isArray(p.uncertainty)||p.uncertainty.length>32||!p.uncertainty.every(v=>text(v,256)))throw Error('Réponse hors du contexte demandé.');
 const evidence=new Map<string,Evidence>();for(const raw of p.evidence){const e=object(raw);if(e.schemaVersion!=='1'||!uuid(e.id)||!same(e.subjectId,entity)||!uuid(e.locationId)||!uuid(e.frameId)||!text(e.source,256)||!score(e.confidence)||!['observed','inferred'].includes(String(e.basis))||!date(e.observedAt)||!date(e.recordedAt)||!optional(e.occurredAt,date)||!text(e.timeZone,128)||!optional(e.observationAgeSeconds,v=>typeof v==='number'&&Number.isFinite(v)&&v>=0)||!['fresh','stale','clock_skew'].includes(String(e.freshness))||evidence.has(e.id.toLowerCase()))throw Error('Preuve invalide.');evidence.set(e.id.toLowerCase(),e as Evidence);}
 let supported=0;
 for(const raw of p.claims){const c=object(raw);if(!same(c.subjectId,entity)||!['unknown','location','change'].includes(String(c.kind))||!Array.isArray(c.citationIds)||c.citationIds.length>16||!c.citationIds.every(uuid)||new Set(c.citationIds.map(v=>v.toLowerCase())).size!==c.citationIds.length)throw Error('Citations invalides.');
  const cited=c.citationIds.map(id=>evidence.get(id.toLowerCase()));if(cited.some(e=>!e))throw Error('Citation absente des preuves.');
  if(c.kind==='unknown'){if(c.basis!=='unknown'||c.citationIds.length||['locationId','frameId','changeId','minimumSourceConfidence','changeKind'].some(k=>c[k]!==undefined))throw Error('Conclusion inconnue incohérente.');}
  else{supported++;if(!uuid(c.locationId)||!uuid(c.frameId)||!score(c.minimumSourceConfidence)||!['observed','inferred'].includes(String(c.basis))||!cited.length)throw Error('Conclusion sans preuve.');if(c.minimumSourceConfidence!==Math.min(...cited.map(e=>e!.confidence))||c.basis!==(cited.some(e=>e!.basis==='inferred')?'inferred':'observed'))throw Error('Confiance ou base incohérente.');if(c.kind==='location'&&cited.some(e=>!same(e!.locationId,c.locationId)||!same(e!.frameId,c.frameId)))throw Error('Citation hors de la position.');if(c.kind==='change'&&(!uuid(c.changeId)||!['observation','location_changed','correction'].includes(String(c.changeKind))))throw Error('Changement invalide.');}
 }
 if((p.status==='unknown')!==(supported===0))throw Error('État de réponse incohérent.');return p as Answer;
}
export type Stream={sequence:number;cursor?:string;actor?:string;phase:number;message?:string;content:string;answer?:Answer;terminal?:'success'|'cancelled'|'error';failure?:string};
export const freshStream=():Stream=>({sequence:0,phase:0,content:''});
export function consume(previous:Stream,body:string,run:Acceptance,entity:string):Stream {
 const s=structuredClone(previous);if(!body.endsWith('\n\n')||body.includes('\r'))throw Error('Flux incomplet.');
 for(const frame of body.slice(0,-2).split('\n\n')){
  if(frame===': keepalive')continue;
  const match=/^id: ([A-Za-z0-9_-]{1,2048})\ndata: (.+)$/.exec(frame);if(!match||s.terminal)throw Error('Flux invalide.');
  const cursor=match[1]!,data=match[2]!;if(!text(data,65536))throw Error('Événement trop volumineux.');
  const base=cursor.replaceAll('-','+').replaceAll('_','/'),c=object(JSON.parse(atob(base+'='.repeat((4-base.length%4)%4))));
  if(c.schemaVersion!=='1'||!same(c.runId,run.runId)||!uuid(c.actorId)||c.afterSequence!==String(s.sequence+1)||s.sequence>=128||(s.actor&&!same(c.actorId,s.actor)))throw Error('Curseur hors séquence ou hors run.');
  const e=object(JSON.parse(data));if(!Number.isSafeInteger(e.timestamp))throw Error('Horodatage du flux invalide.');
  if(s.phase===0){if(e.type!=='RUN_STARTED'||!same(e.runId,run.runId)||!same(e.threadId,run.threadId)||e.protocolVersion!=='1.0')throw Error('Début de run invalide.');s.phase=1;}
  else if(e.type==='RUN_ERROR'){if(s.phase!==1&&s.phase!==5)throw Error('Erreur dans un message incomplet.');if(!['RUN_FAILED','RUN_DEADLINE_EXCEEDED','RUN_RECOVERY_REQUIRED'].includes(String(e.code)))throw Error('Erreur serveur invalide.');s.terminal='error';s.failure=String(e.code);s.answer=undefined;}
  else if(e.type==='RUN_FINISHED'){if(!same(e.runId,run.runId)||!same(e.threadId,run.threadId))throw Error('Fin hors run.');const outcome=object(e.outcome);if(outcome.type==='cancelled'&&(s.phase===1||s.phase===5)){s.terminal='cancelled';s.answer=undefined;}else if(outcome.type==='success'&&s.phase===5&&s.answer&&s.content===s.answer.text)s.terminal='success';else throw Error('Réponse finale incomplète.');}
  else if(s.phase===1&&e.type==='CUSTOM'&&e.name==='squidra.grounded_answer.v1'){s.answer=answer(e.value,run,c.actorId,entity);s.phase=2;}
  else if(s.phase===2&&e.type==='TEXT_MESSAGE_START'&&uuid(e.messageId)&&e.role==='assistant'){s.message=e.messageId;s.phase=3;}
  else if(s.phase===3&&e.type==='TEXT_MESSAGE_CONTENT'&&same(e.messageId,s.message)&&text(e.delta,65536)){s.content+=e.delta;if(!text(s.content,65536))throw Error('Message trop volumineux.');}
  else if(s.phase===3&&e.type==='TEXT_MESSAGE_END'&&same(e.messageId,s.message)&&s.content===s.answer?.text)s.phase=5;
  else throw Error('Ordre des événements invalide.');
  s.sequence++;s.cursor=cursor;s.actor=c.actorId;
 }
 return s;
}
