import { test, expect, type Page } from '@playwright/test';
const id='10000000-0000-0000-0000-000000000001', token='a'.repeat(64);
const preview=()=>({schemaVersion:'1',id,runId:'20000000-0000-0000-0000-000000000002',ledgerId:'30000000-0000-0000-0000-000000000003',decision:'pending',version:0,digest:'b'.repeat(64),commandFingerprint:'c'.repeat(64),tool:'fixture.send@1.0.0',target:'recipient:authored',argumentsJSON:'{"message":"<script>window.compromised=true</script>"}',scope:['message:send'],requestedAt:new Date().toISOString(),expiresAt:new Date(Date.now()+600000).toISOString()});
async function open(page:Page) { await page.goto('/approvals'); await page.locator('#token').fill(token); await page.locator('#approval').fill(id); await page.getByRole('button',{name:'Consulter la commande'}).click(); }
async function fixture(page:Page, response?: (p:ReturnType<typeof preview>,body:any)=>unknown) {
  const posts:any[]=[]; const p=preview();
  await page.route('http://127.0.0.1:8080/**',async route=>{expect(route.request().headers().authorization).toBe('Bearer '+token); if(route.request().method()==='POST') { const body=route.request().postDataJSON(); posts.push(body); await route.fulfill({json:response ? response(p,body) : {...p,decision:body.decision,version:1,decidedAt:new Date().toISOString()}}); } else await route.fulfill({json:p});}); return posts;
}
test('keyboard confirmation sends only exact digest and preserves hostile command text',async({page})=>{
  const posts=await fixture(page); await open(page); await expect(page.getByRole('heading',{name:'Commande à examiner'})).toBeFocused(); await expect(page.locator('pre')).toHaveText(preview().argumentsJSON); await expect(page.locator('#detail script')).toHaveCount(0);
  await page.getByRole('button',{name:'Autoriser',exact:true}).focus(); await page.keyboard.press('Enter'); await expect(page.getByRole('button',{name:'Annuler'})).toBeFocused(); await page.keyboard.press('Escape'); expect(posts).toHaveLength(0);
  await page.getByRole('button',{name:'Autoriser',exact:true}).click(); await page.getByRole('button',{name:'Confirmer',exact:true}).click(); await expect(page.getByRole('status')).toContainText('Autorisée · exécution non confirmée');
  expect(posts).toEqual([{schemaVersion:'1',decision:'approved',digest:'b'.repeat(64)}]); await expect(page.getByRole('button',{name:'Autoriser',exact:true})).toHaveCount(0);
  expect(await page.evaluate(()=>(window as any).compromised)).toBeUndefined(); await page.screenshot({path:'test-results/approval.png',fullPage:true});
});
test('denial and withdrawal remain explicit terminal decisions',async({page})=>{
  const posts=await fixture(page);
  for(const [button,decision,label] of [['Refuser','denied','Refusée'],['Retirer','withdrawn','Retirée']]) { await open(page); await page.getByRole('button',{name:button!,exact:true}).click(); await page.getByRole('button',{name:'Confirmer',exact:true}).click(); await expect(page.getByRole('status')).toContainText(label!); expect(posts.at(-1).decision).toBe(decision); await expect(page.getByRole('button',{name:'Autoriser',exact:true})).toHaveCount(0); }
});
test('local deadline closes confirmation without posting and server expired state has no actions',async({page})=>{
  await page.clock.install(); const posts=await fixture(page); await open(page); await page.getByRole('button',{name:'Autoriser',exact:true}).click(); await page.clock.fastForward(600001);
  await expect(page.locator('#confirm')).not.toBeVisible(); await expect(page.locator('#detail')).toContainText('Échéance atteinte'); expect(posts).toHaveLength(0);
  await page.unrouteAll(); await page.route('http://127.0.0.1:8080/**',route=>route.fulfill({json:{...preview(),decision:'expired',version:1,decidedAt:new Date().toISOString()}})); await page.getByRole('button',{name:'Actualiser la demande'}).click(); await expect(page.getByRole('status')).toContainText('Expirée'); await expect(page.getByRole('button',{name:'Autoriser',exact:true})).toHaveCount(0);
});
test('changed command response cannot confirm authorization and stale decisions require refresh',async({page})=>{
  await fixture(page,(p,b)=>({...p,target:'different target',decision:b.decision,version:1,decidedAt:new Date().toISOString()})); await open(page); await page.getByRole('button',{name:'Autoriser',exact:true}).click(); await page.getByRole('button',{name:'Confirmer',exact:true}).click(); await expect(page.getByRole('alert')).toContainText('commande exacte'); await expect(page.locator('#detail')).toBeEmpty();
  await page.unrouteAll(); await fixture(page); await page.route('**/decision',route=>route.fulfill({status:409,json:{}})); await page.getByRole('button',{name:'Actualiser la demande'}).click(); await page.getByRole('button',{name:'Autoriser',exact:true}).click(); await page.getByRole('button',{name:'Confirmer',exact:true}).click(); await expect(page.getByRole('alert')).toContainText('expirée ou modifiée'); await expect(page.getByRole('status')).not.toContainText('enregistrée');
});
test('unavailability, malformed payload and unauthorized sessions are visible failures',async({page})=>{
  await page.route('http://127.0.0.1:8080/**',route=>route.fulfill({status:503,json:{}})); await open(page); await expect(page.getByRole('alert')).toContainText('indisponible');
  await page.unrouteAll(); await page.route('http://127.0.0.1:8080/**',route=>route.fulfill({json:{...preview(),digest:'forged'}})); await open(page); await expect(page.getByRole('alert')).toContainText('invalide');
  await page.unrouteAll(); await page.route('http://127.0.0.1:8080/**',route=>route.fulfill({status:401,json:{}})); await open(page); await expect(page.getByRole('alert')).toContainText('Session refusée'); await expect(page.locator('#workspace')).toBeHidden(); await expect(page.locator('#token')).toHaveValue('');
});
test('off-host destination and late preview after logout cannot leak or reopen session',async({page})=>{
  let calls=0; await page.route('http://example.com/**',async route=>{calls++;await route.abort();}); await page.goto('/approvals'); await page.locator('#origin').fill('http://example.com'); await page.locator('#token').fill(token); await page.locator('#approval').fill(id); await page.getByRole('button',{name:'Consulter la commande'}).click(); await expect(page.getByRole('alert')).toBeVisible(); expect(calls).toBe(0);
  let release!:()=>void,reached!:()=>void; const gate=new Promise<void>(r=>release=r), arrival=new Promise<void>(r=>reached=r);
  await page.route('http://127.0.0.1:8080/**',async route=>{reached();await gate;await route.fulfill({json:preview()}).catch(()=>{});}); await open(page); await arrival; await page.getByRole('button',{name:'Se déconnecter'}).click(); release(); await expect(page.locator('#workspace')).toBeHidden(); await expect(page.locator('#detail')).toBeEmpty(); await expect(page.locator('#token')).toHaveValue('');
  expect(await page.evaluate(()=>[localStorage.length,sessionStorage.length,document.cookie])).toEqual([0,0,'']); expect(page.url()).not.toContain(token);
});
