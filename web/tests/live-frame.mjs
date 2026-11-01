// Actual static UI, normal CLI and isolated PostgreSQL. No route interception.
import {readFile,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {chromium,expect} from '@playwright/test';
const path=process.env.SQUIDRA_WEB_MANIFEST,m=JSON.parse(await readFile(path,'utf8'));
const mode=process.env.SQUIDRA_WEB_PHASE;
if(!['import','reload'].includes(mode))throw Error('Invalid browser phase');
const fixture=JSON.parse(await readFile(new URL('../../fixtures/providers/vision-synthetic.v1.json',import.meta.url),'utf8'));
const png=Buffer.from(fixture.frames[0].imageBase64,'base64');
const browser=await chromium.launch();
process.once('SIGTERM',async()=>{await browser.close();process.exit(1);});
const sameID=(a,b)=>a.toLowerCase()===b.toLowerCase();
try {
 const page=await browser.newPage(),errors=[];let imports=0;
 page.on('pageerror',()=>errors.push('pageerror'));
 page.on('request',request=>{if(request.url().endsWith('/api/v1/frames/import')&&request.method()==='POST')imports++;});
 await page.goto(process.env.SQUIDRA_WEB_ORIGIN+'/import');
 await page.locator('#origin').fill(process.env.SQUIDRA_API_ORIGIN);
 await page.locator('#token').fill(process.env.SQUIDRA_WEB_TOKEN);
 await page.getByRole('button',{name:'Se connecter',exact:true}).click();
 await expect(page.locator('#image')).toBeFocused();
 await expect(page.locator('#capability')).toContainText('aucun moteur de lecture configuré');
 let r;
 if(mode==='import') {
  // A valid PNG with an extra ancillary tEXt chunk is outside the frozen fixture.
  const chunk=Buffer.from([0,0,0,3,116,69,88,116,97,0,98,0,0,0,0]);let crc=0xffffffff;
  for(const byte of chunk.subarray(4,11)){crc^=byte;for(let i=0;i<8;i++)crc=(crc>>>1)^((crc&1)?0xedb88320:0);}chunk.writeUInt32BE((crc^0xffffffff)>>>0,11);
  const unknown=Buffer.concat([png.subarray(0,-12),chunk,png.subarray(-12)]);
  await page.locator('#image').setInputFiles({name:'unknown.png',mimeType:'image/png',buffer:unknown});
  await page.locator('#submit-import').click();expect(imports,'consent blocks import').toBe(0);
  await page.locator('#consent').check();await page.locator('#submit-import').click();
  await expect(page.getByRole('alert')).toContainText('image non prise en charge');
  await expect(page.locator('#receipt')).toBeEmpty();expect(imports,'one rejected image').toBe(1);
  await page.locator('#new-import').click();await expect(page.locator('#consent')).not.toBeChecked();
  await page.locator('#image').setInputFiles({name:'fixture.png',mimeType:'image/png',buffer:png});
  await page.locator('#consent').check();await page.locator('#submit-import').focus();
  const responsePromise=page.waitForResponse(response=>response.url().endsWith('/api/v1/frames/import')&&response.request().method()==='POST');
  await page.keyboard.press('Enter');const response=await responsePromise;
  expect(response.status(),'created import receipt').toBe(201);expect(response.headers()['cache-control']).toBe('no-store');r=await response.json();
  await expect(page.getByRole('heading',{name:'Observation synthétique enregistrée'})).toBeFocused();
  for(const value of [r.imageSHA256,r.observedAt,r.knownAt,r.frameId,r.cameraId,r.locationId,r.coordinateFrameId,r.observationEventId,...r.entities.flatMap(e=>[e.id,e.sourceEventId])])await expect(page.locator('#receipt')).toContainText(value);
  expect(r.imageSHA256).toBe(createHash('sha256').update(png).digest('hex'));expect(r.deployment).toBe('synthetic');expect(r.basis).toBe('inferred');expect(r.mediaRetained).toBe(false);
  expect(sameID(r.cameraId,m.camera)&&sameID(r.locationId,m.scene)&&sameID(r.coordinateFrameId,m.coordinate)).toBe(true);
  expect(imports,'exactly one failed and one successful import').toBe(2);
  await expect(page.locator('#image')).toHaveValue('');await expect(page.locator('#consent')).not.toBeChecked();
  await writeFile(path+'.receipt.json',JSON.stringify(r),{mode:0o600});
 } else {
  r=JSON.parse(await readFile(path+'.receipt.json','utf8'));
  await expect(page.locator('#receipt')).toBeEmpty();expect(imports,'reload never repeats import').toBe(0);
 }
 // Independent authenticated API readback from the real browser origin. This is
 // a structured evidence check, not a user-facing free-text answer qualification.
 const states=await page.evaluate(async({origin,token,r})=>{
  const result=[];
  for(const entity of r.entities){const response=await fetch(origin+'/api/v1/world/location',{method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},credentials:'omit',redirect:'error',body:JSON.stringify({schemaVersion:'1',entityId:entity.id,validAt:r.observedAt,knownAt:r.knownAt})});if(!response.ok)throw Error('Evidence query failed');result.push(await response.json());}return result;
 },{origin:process.env.SQUIDRA_API_ORIGIN,token:process.env.SQUIDRA_WEB_TOKEN,r});
 for(let i=0;i<r.entities.length;i++){
  const state=states[i],entity=r.entities[i];expect(state.facts).toHaveLength(1);expect(state.uncertainty).toEqual(['inferredEvidence']);const fact=state.facts[0];
  expect(sameID(fact.subjectId,entity.id)&&sameID(fact.sourceEventId,entity.sourceEventId)&&sameID(fact.locationId,m.scene)&&sameID(fact.frameId,m.coordinate)).toBe(true);
  expect(fact.observedAt).toBe(r.observedAt);expect(fact.valid.from).toBe(r.observedAt);expect(fact.basis).toBe('inferred');expect(fact.confidence).toBe(0.875);expect(fact.source).toBe('synthetic-frame:'+r.imageSHA256);
 }
 if(mode==='import')await writeFile(path+'.states.json',JSON.stringify(states),{mode:0o600});
 else expect(states,'exact historical evidence after restart').toEqual(JSON.parse(await readFile(path+'.states.json','utf8')));
 await page.locator('#logout').click();await expect(page.locator('#receipt')).toBeEmpty();await expect(page.locator('#token')).toHaveValue('');
 await page.locator('#token').fill('0'.repeat(64));await page.getByRole('button',{name:'Se connecter',exact:true}).click();await expect(page.getByRole('alert')).toContainText('Session refusée');await expect(page.locator('#workspace')).toBeHidden();
 if(await page.evaluate(()=>localStorage.length+sessionStorage.length+document.cookie.length)||errors.length)throw Error('Browser privacy/runtime failure');
 console.log('SQUIDRA_FRAME_LIVE_PASS:'+mode);
}finally{await browser.close();}
