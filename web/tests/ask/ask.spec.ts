import {test,expect,type Page} from '@playwright/test';
import {createHash} from 'node:crypto';
const id=(n:number)=>`10000000-0000-0000-0000-${String(n).padStart(12,'0')}`,token='a'.repeat(64),entity=id(6),actor=id(2);
test.use({launchOptions:{args:['--use-fake-device-for-media-stream','--use-fake-ui-for-media-stream']},permissions:['camera']});
const accepted={schemaVersion:'1',runId:id(3),threadId:id(4),requestId:id(5),traceId:id(16),status:'/api/v1/runs/'+id(3),events:'/api/v1/runs/'+id(3)+'/events'};
const answer={schemaVersion:'1',actorId:actor,requestId:accepted.requestId,intent:'historical',status:'grounded',text:'La tasse est sur la table <b>x</b>',claims:[{kind:'location',subjectId:entity,locationId:id(7),frameId:id(8),basis:'inferred',minimumSourceConfidence:0.875,citationIds:[id(9)]}],evidence:[{schemaVersion:'1',id:id(9),subjectId:entity,locationId:id(7),frameId:id(8),source:'meta.sam',confidence:0.875,basis:'inferred',observedAt:'2026-11-01T12:00:00.123456Z',recordedAt:'2026-11-01T12:00:01.654321Z',timeZone:'Etc/UTC',observationAgeSeconds:1.5,freshness:'fresh'}],uncertainty:['inferredEvidence']};
const events=[{type:'RUN_STARTED',runId:accepted.runId,threadId:accepted.threadId,protocolVersion:'1.0'},{type:'CUSTOM',name:'squidra.grounded_answer.v1',value:answer},{type:'TEXT_MESSAGE_START',messageId:id(10),role:'assistant'},{type:'TEXT_MESSAGE_CONTENT',messageId:id(10),delta:answer.text},{type:'TEXT_MESSAGE_END',messageId:id(10)},{type:'RUN_FINISHED',runId:accepted.runId,threadId:accepted.threadId,outcome:{type:'success'}}].map(e=>({...e,timestamp:1793534400000}));
const cursor=(n:number)=>Buffer.from(JSON.stringify({actorId:actor,afterSequence:String(n),runId:accepted.runId,schemaVersion:'1'})).toString('base64url');
const frames=(es:any[],offset=0)=>es.map((e,i)=>`id: ${cursor(offset+i+1)}\ndata: ${JSON.stringify(e)}\n\n`).join('');
async function setup(page:Page){
 const imports:any[]=[],runs:any[]=[];
 await page.route('http://127.0.0.1:8080/**',async route=>{
  const url=route.request().url();expect(route.request().headers().authorization).toBe('Bearer '+token);
  if(url.endsWith('/run-capabilities'))return route.fulfill({json:{schemaVersion:'1',textRuns:true}});
  if(url.endsWith('/frame-import-capabilities'))return route.fulfill({json:{schemaVersion:'1',deployment:'cloud',maximumImageBytes:65536,requiresCloudTransferConsent:true}});
  if(url.endsWith('/frames/import')){const body=route.request().postDataJSON();imports.push(body);const hash=createHash('sha256').update(Buffer.from(body.imageBase64,'base64')).digest('hex');
   return route.fulfill({status:201,json:{schemaVersion:'1',deployment:'cloud',basis:'inferred',mediaRetained:false,frameId:id(1),cameraId:id(12),locationId:id(13),coordinateFrameId:id(14),modelId:'meta.sam',modelVersion:'alias:sam-3.1',imageSHA256:hash,observedAt:'2026-11-01T12:01:02.123456Z',knownAt:'2026-11-01T12:01:02.456789Z',validityMilliseconds:1000,observationEventId:id(15),entities:[{id:entity,localId:'tasse_rouge',sourceEventId:id(17)}]}});}
  if(route.request().method()==='POST'){runs.push(route.request().postDataJSON());return route.fulfill({status:202,json:accepted});}
  const last=route.request().headers()['last-event-id'];const off=last?Number(JSON.parse(Buffer.from(last,'base64url').toString()).afterSequence):0;
  return route.fulfill({contentType:'text/event-stream; charset=utf-8',body:frames(events.slice(off,off+2),off)});
 });
 return {imports,runs};
}
async function connect(page:Page){await page.goto('/ask');await page.locator('#token').fill(token);await page.getByRole('button',{name:'Se connecter',exact:true}).click();await expect(page.locator('#chat')).toBeVisible();}
test('camera photo is sent to SAM after consent, then a question is answered with proof',async({page})=>{
 const f=await setup(page);await connect(page);
 await page.locator('#camera').click();await expect(page.locator('#camera-panel')).toBeVisible();
 await page.locator('#shoot').click();await expect(page.locator('#attachment')).toBeVisible();await expect(page.locator('#camera-panel')).toBeHidden();
 await page.locator('#message').fill('Où est la tasse ?');
 await page.locator('#send').click();await expect(page.getByRole('alert')).toContainText('Cochez');expect(f.imports).toHaveLength(0);
 await page.locator('#consent').check();await page.locator('#send').click();
 await expect(page.locator('.answer-text')).toHaveText('La tasse est sur la table <b>x</b>');
 await expect(page.locator('#log b')).toHaveCount(0);
 expect(f.imports).toHaveLength(1);expect(f.imports[0].permitsCloudTransfer).toBe(true);expect(Buffer.from(f.imports[0].imageBase64,'base64').length).toBeLessThanOrEqual(65536);
 expect(f.runs).toEqual([{schemaVersion:'1',question:'Où est la tasse ?\n\n(Photo observée le 2026-11-01T12:01:02.123456Z, enregistrée le 2026-11-01T12:01:02.456789Z.)',entityId:entity,intent:'historical'}]);
 await page.getByText('Voir les preuves').click();await expect(page.locator('.proof')).toContainText('meta.sam');
 await expect(page.locator('#context')).toContainText('tasse rouge');
 await page.screenshot({path:'test-results/ask.png',fullPage:true});
 await page.locator('#logout').click();await expect(page.locator('#log')).toBeEmpty();await expect(page.locator('#token')).toHaveValue('');
 expect(await page.evaluate(()=>[localStorage.length,sessionStorage.length,document.cookie])).toEqual([0,0,'']);
});
test('a question without any object asks for a photo and sends nothing',async({page})=>{
 const f=await setup(page);await connect(page);await page.locator('#message').fill('Où est la tasse ?');await page.locator('#send').click();
 await expect(page.getByRole('alert')).toContainText('photo');expect(f.runs).toHaveLength(0);expect(f.imports).toHaveLength(0);
});
test('foreign origin is refused before any request',async({page})=>{
 let leaked=0;await page.route('http://example.com/**',r=>{leaked++;return r.abort();});
 await page.goto('/ask');await page.getByText('Réglages avancés').click();await page.locator('#origin').fill('http://example.com');await page.locator('#token').fill(token);
 await page.getByRole('button',{name:'Se connecter',exact:true}).click();await expect(page.getByRole('alert')).toBeVisible();expect(leaked).toBe(0);
});
