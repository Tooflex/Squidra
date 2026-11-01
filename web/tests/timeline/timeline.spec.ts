import { test, expect, type Page } from '@playwright/test';
const id = (n: number) => `10000000-0000-0000-0000-${String(n).padStart(12,'0')}`;
const subject = id(1), actor = id(2), token = 'b'.repeat(64);
const early = '2026-01-02T12:00:00Z', late = '2026-01-04T12:00:00Z', valid = '2026-01-01T12:00:00Z';
const fact = (corrected = false) => ({ id:id(corrected ? 4 : 3), subjectId:subject, locationId:id(corrected ? 6 : 5), frameId:id(7), sourceEventId:id(corrected ? 4 : 3), source:'<script>window.compromised=true</script>', confidence:0.8, basis:'observed', occurredAt:null, observedAt:valid, recordedAt:corrected ? '2026-01-03T00:00:00Z' : '2026-01-01T13:00:00Z', timeZone:'Etc/UTC', valid:{from:valid,to:null}, transaction:{from:corrected ? '2026-01-03T00:00:00Z' : '2026-01-01T13:00:00Z',to:null} });
async function connect(page: Page) {
  await page.goto('/timeline'); await page.getByLabel('Jeton de session').fill(token); await page.getByRole('button',{name:'Ouvrir la chronologie'}).click();
  await expect(page.locator('#query-title')).toBeFocused();
  await page.getByLabel('Identifiant de l’entité').fill(subject);
  for (const [field,value] of [['valid',valid],['known',early],['from','2026-01-01T00:00:00Z'],['to','2026-01-02T00:00:00Z']]) await page.locator('#'+field).fill(value!.slice(0,16));
}
async function mock(page: Page) {
  const requests: {path: string; body: any; auth: string}[] = [];
  await page.route('http://127.0.0.1:8080/**', async route => {
    const body = route.request().postDataJSON(), path = route.request().url().split('/').at(-1)!;
    requests.push({path,body,auth:route.request().headers().authorization!});
    const corrected = body.knownAt === late, f = fact(corrected), previous = {...fact(),transaction:{from:'2026-01-01T13:00:00Z',to:'2026-01-03T00:00:00Z'}};
    if (path === 'location') await route.fulfill({json:{schemaVersion:'1',actorId:actor,entityId:subject,validAt:body.validAt,knownAt:body.knownAt,status:'evidence',facts:[f],uncertainty:[],projectedThroughSequence:'2',availableThroughSequence:'2'}});
    else await route.fulfill({json:{schemaVersion:'1',actorId:actor,subjectId:subject,locationId:null,from:body.from,to:body.to,knownAt:body.knownAt,facts:corrected ? [f,previous] : [f],changes:[{id:f.id,subjectId:subject,kind:corrected ? 'correction' : 'observation',effectiveAt:valid,currentFactId:f.id,previousFactIds:corrected ? [previous.id] : [],supportingEventIds:corrected ? [f.id,previous.id] : [f.id],uncertainty:[]}],projectedThroughSequence:'2',availableThroughSequence:'2',projectionBehind:false,next:null}});
  }); return requests;
}
const show = (page: Page) => page.getByRole('button',{name:'Afficher l’état et les changements'}).click();
test('UI-023 keyboard selection keeps valid time and reveals late correction with original evidence',async ({page}) => {
  const requests = await mock(page); await connect(page);
  await page.getByRole('button',{name:'Afficher l’état et les changements'}).focus(); await page.keyboard.press('Enter');
  await expect(page.getByRole('heading',{name:'État à l’instant choisi'})).toBeFocused();
  await expect(page.locator('#result')).toContainText(id(5)); await expect(page.locator('#result')).not.toContainText('Correction tardive');
  await page.locator('#known').fill(late.slice(0,16)); await expect(page.locator('#result')).toBeEmpty(); await show(page);
  await expect(page.locator('summary')).toContainText('Correction tardive'); await page.locator('summary').focus(); await page.keyboard.press('Enter');
  await expect(page.getByText('Preuve précédente',{exact:true})).toBeVisible(); await expect(page.locator('#changes-page')).toContainText(id(5)); await expect(page.locator('#changes-page')).toContainText(id(6));
  expect(requests.filter(r=>r.path==='location').map(r=>[r.body.validAt,r.body.knownAt])).toEqual([[valid,early],[valid,late]]);
  expect(requests.every(r=>r.auth==='Bearer '+token)).toBeTruthy();
  expect(await page.evaluate(()=>(window as any).compromised)).toBeUndefined(); await expect(page.locator('#result script')).toHaveCount(0);
  await page.screenshot({path:'test-results/timeline.png',fullPage:true});
});
test('unavailability and mismatched response never display a state',async ({page}) => {
  await page.route('http://127.0.0.1:8080/**',route=>route.fulfill({status:503,json:{}})); await connect(page); await show(page);
  await expect(page.getByRole('alert')).toContainText('indisponible'); await expect(page.locator('#result')).toBeEmpty();
  await page.unrouteAll(); await mock(page); await page.route('**/world/location',route=>route.fulfill({json:{schemaVersion:'1',entityId:id(99)}})); await show(page);
  await expect(page.getByRole('alert')).toContainText('invalide'); await expect(page.locator('#result')).toBeEmpty();
});
test('logout clears results and credentials; unauthorized reads return to connection',async ({page}) => {
  await mock(page); await connect(page); await show(page); await expect(page.locator('#result')).not.toBeEmpty();
  await page.getByRole('button',{name:'Se déconnecter'}).click(); await expect(page.locator('#result')).toBeEmpty(); await expect(page.locator('#token')).toHaveValue('');
  expect(await page.evaluate(()=>[localStorage.length,sessionStorage.length,document.cookie])).toEqual([0,0,'']); expect(page.url()).not.toContain(token);
  await page.unrouteAll(); await page.route('http://127.0.0.1:8080/**',route=>route.fulfill({status:401,json:{}})); await connect(page); await show(page);
  await expect(page.locator('#workspace')).toBeHidden(); await expect(page.getByRole('alert')).toContainText('Session refusée');
});
test('off-host origins send no credentials and stale reads cannot repopulate after date edits',async ({page}) => {
  let calls = 0; await page.route('http://example.com/**',async route=>{calls++; await route.abort();}); await page.goto('/timeline'); await page.locator('#origin').fill('http://example.com'); await page.locator('#token').fill(token); await page.getByRole('button',{name:'Ouvrir la chronologie'}).click(); await expect(page.getByRole('alert')).toBeVisible(); expect(calls).toBe(0);
  await connect(page); let reached!:()=>void; const arrival = new Promise<void>(r=>reached=r); let release!:()=>void; const gate = new Promise<void>(r=>release=r);
  await page.route('**/world/location',async route=>{reached(); await gate; await route.fulfill({json:{}}).catch(()=>{});});
  await show(page); await arrival; await page.locator('#known').fill(late.slice(0,16)); release();
  await expect(page.getByRole('status')).toContainText('Dates modifiées'); await expect(page.locator('#result')).toBeEmpty(); await expect(page.locator('#next')).toBeHidden();
});
test('contradictions remain visible and continuation preserves the original query',async ({page}) => {
  const requests = await mock(page); let locationBody: any;
  await page.route('**/world/location',async route=>{locationBody=route.request().postDataJSON(); await route.fulfill({json:{schemaVersion:'1',actorId:actor,entityId:subject,validAt:locationBody.validAt,knownAt:locationBody.knownAt,status:'evidence',facts:[fact(),fact(true)],uncertainty:['conflictingLocations','projectionBehind'],projectedThroughSequence:'2',availableThroughSequence:'3'}});});
  const continuation: any[] = [];
  await page.route('**/world/changes',async route=>{const b=route.request().postDataJSON(); continuation.push(b); const f=fact(); await route.fulfill({json:{schemaVersion:'1',actorId:actor,subjectId:subject,locationId:null,from:b.from,to:b.to,knownAt:b.knownAt,facts:[f],changes:b.cursor ? [] : [{id:f.id,subjectId:subject,kind:'observation',effectiveAt:valid,currentFactId:f.id,previousFactIds:[],supportingEventIds:[f.id],uncertainty:['conflictingLocations']}],projectedThroughSequence:'2',availableThroughSequence:'3',projectionBehind:true,next:b.cursor ? null : 'opaque-fixture-cursor'}});});
  await connect(page); await show(page); await expect(page.locator('#result')).toContainText('Emplacements contradictoires'); await expect(page.locator('#next')).toBeVisible();
  await page.locator('#next').focus(); await page.keyboard.press('Enter'); await expect(page.getByRole('heading',{name:'Changements dans la période'})).toBeFocused(); await expect(page.locator('#next')).toBeHidden();
  expect(continuation[1]).toEqual({...continuation[0],cursor:'opaque-fixture-cursor'}); await expect(page.locator('#changes-page')).toHaveCount(1);
  expect(requests.length).toBe(0);
});
test('no evidence is distinct from inaccessible entity and a failed read',async ({page}) => {
  await mock(page); let absent = false;
  await page.route('**/world/location',async route=>{const b=route.request().postDataJSON(); await route.fulfill({json:{schemaVersion:'1',actorId:actor,entityId:subject,validAt:b.validAt,knownAt:b.knownAt,status:absent ? 'not_found' : 'no_evidence',facts:[],uncertainty:['noEvidence'],projectedThroughSequence:absent ? null : '2',availableThroughSequence:absent ? null : '2'}});});
  await page.route('**/world/changes',async route=>{const b=route.request().postDataJSON(); await route.fulfill({json:{schemaVersion:'1',actorId:actor,subjectId:subject,locationId:null,from:b.from,to:b.to,knownAt:b.knownAt,facts:[],changes:[],projectedThroughSequence:'2',availableThroughSequence:'2',projectionBehind:false,next:null}});});
  await connect(page); await show(page); await expect(page.locator('#result')).toContainText('Aucune preuve disponible.'); await expect(page.getByRole('alert')).toBeHidden();
  absent=true; await show(page); await expect(page.locator('#result')).toContainText('Entité absente ou inaccessible.'); await expect(page.locator('#result')).not.toContainText('Aucune preuve disponible.');
});
