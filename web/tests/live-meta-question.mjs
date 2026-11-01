// Explicit opt-in only: real normal CLI + Meta + isolated public fixture data.
import {readFile,writeFile} from 'node:fs/promises';
import {chromium,expect} from '@playwright/test';
if(process.env.SQUIDRA_META_QUESTION_LIVE!=='1')throw Error('Live opt-in required');
const sam=process.env.SQUIDRA_SAM_QUESTION_LIVE==='1';
const manifest=process.env.SQUIDRA_WEB_MANIFEST,reportPath=process.env.SQUIDRA_META_REPORT;
const m=JSON.parse(await readFile(manifest,'utf8'));
const fixture=JSON.parse(await readFile(new URL('../../fixtures/providers/vision-synthetic.v1.json',import.meta.url),'utf8'));
const browser=await chromium.launch();let run,answer;const events=[],errors=[];
const report={schemaVersion:1,checkedAt:new Date().toISOString(),model:'muse-spark-1.3',outcome:'failed',source:sam?'public_sam_image':'authored_synthetic'};
process.once('SIGTERM',async()=>{await browser.close();process.exit(1);});
try {
 const page=await browser.newPage();let posts=0;
 page.on('pageerror',()=>errors.push('pageerror'));
 page.on('request',r=>{if(r.method()==='POST'&&r.url().endsWith('/api/v1/runs'))posts++;});
 async function login(path){await page.goto(process.env.SQUIDRA_WEB_ORIGIN+path);await page.locator('#origin').fill(process.env.SQUIDRA_API_ORIGIN);await page.locator('#token').fill(process.env.SQUIDRA_WEB_TOKEN);await page.getByRole('button',{name:'Se connecter',exact:true}).click();await expect(page.locator('#workspace')).toBeVisible();}
 await login('/import');
 await page.locator('#image').setInputFiles({name:'public-fixture.png',mimeType:'image/png',buffer:sam?await readFile(new URL('../../fixtures/providers/sam-red-square.png',import.meta.url)):Buffer.from(fixture.frames[0].imageBase64,'base64')});
 await page.locator('#consent').check();
 if(sam)await page.locator('#cloud-consent').check();
 const imported=page.waitForResponse(r=>r.url().endsWith('/api/v1/frames/import')&&r.request().method()==='POST');
 await page.locator('#submit-import').click();const receiptResponse=await imported;expect(receiptResponse.status()).toBe(201);
 const receipt=await receiptResponse.json();expect(receipt.deployment).toBe(sam?'cloud':'synthetic');expect(receipt.modelId).toBe(sam?'meta.sam':'fixture.vision');expect(receipt.modelVersion).toBe(sam?'alias:sam-3.1':'1.0.0');await writeFile(manifest+'.receipt.json',JSON.stringify(receipt),{mode:0o600});
 const entity=receipt.entities.at(-1),question=`Quelle était la position de cette entité au ${receipt.observedAt}, selon les informations connues au ${receipt.knownAt} ? Cite les preuves et précise si la position est observée ou inférée.`;
 report.question=question;report.receipt=receipt;
 await login('/questions');await expect(page.locator('#entity')).toBeFocused();
 await page.locator('#entity').fill(entity.id);await page.locator('#question').fill(question);
 const accepted=page.waitForResponse(r=>r.url().endsWith('/api/v1/runs')&&r.request().method()==='POST');
 await page.locator('#submit-question').click();const acceptedResponse=await accepted;expect(acceptedResponse.status()).toBe(202);run=await acceptedResponse.json();report.run=run;
 // Read through the actual UI; resuming GETs must never repeat paid submission.
 const end=Date.now()+180000;
 while(Date.now()<end){
  if(await page.locator('#answer h2').count())break;
  const status=await page.locator('#status').textContent();
  if(status.includes('Run en échec')||status.includes('Run annulé')||await page.locator('#error').isVisible())break;
  if(await page.locator('#continue').isVisible()&&await page.locator('#continue').isEnabled())await page.locator('#continue').click();
  await page.waitForTimeout(250);
 }
 report.uiStatus=await page.locator('#status').textContent();report.uiError=await page.locator('#error').textContent();
 // Independent read-only replay/trace verifies the rendered answer's exact source.
 const result=await page.evaluate(async({origin,token,run})=>{
  async function get(path){const r=await fetch(origin+path,{headers:{Authorization:'Bearer '+token},credentials:'omit',redirect:'error'});if(!r.ok)throw Error('readback failed');return r;}
  return {status:await(await get(run.status)).json(),sse:await(await get(run.events)).text(),trace:await(await get(run.status+'/trace')).json()};
 },{origin:process.env.SQUIDRA_API_ORIGIN,token:process.env.SQUIDRA_WEB_TOKEN,run});
 for(const line of result.sse.split('\n'))if(line.startsWith('data: '))events.push(JSON.parse(line.slice(6)));
 answer=events.find(e=>e.type==='CUSTOM'&&e.name==='squidra.grounded_answer.v1')?.value;
 report.runStatus=result.status;report.eventTypes=events.map(e=>e.type);report.answer=answer??null;
 report.modelUsage=result.trace.spans.filter(s=>s.stage==='model').map(s=>({outcome:s.outcome,outputTokens:s.attributes['squidra.output_tokens'],estimatedCostMicroUSD:s.attributes['squidra.estimated_cost_micro_usd']}));
 expect(posts,'one submission only').toBe(1);expect(errors).toEqual([]);
 await expect(page.getByRole('heading',{name:'Réponse avec preuves'})).toBeVisible();
 expect(answer.status).toBe('grounded');expect(answer.uncertainty).toContain('inferredEvidence');
 const same=(a,b)=>a.toLowerCase()===b.toLowerCase();
 const proof=answer.evidence.find(e=>same(e.id,entity.sourceEventId));expect(proof).toBeTruthy();
 expect(same(proof.subjectId,entity.id)&&same(proof.locationId,m.scene)&&same(proof.frameId,m.coordinate)).toBe(true);
 expect(proof.observedAt).toBe(receipt.observedAt);expect(proof.recordedAt).toBe(receipt.knownAt);if(sam){expect(proof.confidence).toBeGreaterThanOrEqual(0.5);expect(proof.confidence).toBeLessThanOrEqual(1);}else expect(proof.confidence).toBe(0.875);expect(proof.basis).toBe('inferred');
 expect(proof.source).toBe((sam?'cloud-frame:':'synthetic-frame:')+receipt.imageSHA256);
 // Save proof for the independent SQL verifier to compare with actual detection confidence.
 await writeFile(manifest+'.proof.json',JSON.stringify(proof),{mode:0o600});
 expect(answer.claims.some(c=>c.kind==='location'&&same(c.subjectId,entity.id)&&c.citationIds.some(id=>same(id,entity.sourceEventId)))).toBe(true);
 const link=page.getByRole('link',{name:'Preuve '+proof.id,exact:true});await link.focus();await page.keyboard.press('Enter');await expect(page.locator('#proof-'+proof.id.toLowerCase())).toBeFocused();
 await page.screenshot({path:reportPath+'.png',fullPage:true});
 await page.locator('#logout').click();await expect(page.locator('#answer')).toBeEmpty();
 expect(await page.evaluate(()=>localStorage.length+sessionStorage.length+document.cookie.length)).toBe(0);
 report.outcome='passed';console.log('SQUIDRA_META_QUESTION_PASS');
}catch(error){report.diagnostic=String(error?.message??'browser_failure').split(process.env.SQUIDRA_WEB_TOKEN).join('[REDACTED]').slice(0,4000);throw Error('Browser qualification failed; inspect sanitized report');}finally{await writeFile(reportPath,JSON.stringify(report,null,2)+'\n',{mode:0o600});await browser.close();}
