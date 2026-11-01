// Real normal server and SQL; no request interception and no executor.
import { readFile } from 'node:fs/promises';
import { chromium, expect } from '@playwright/test';
const m=JSON.parse(await readFile(process.env.SQUIDRA_WEB_MANIFEST,'utf8')), mode=process.env.SQUIDRA_WEB_PHASE;
if(!['decide','reload'].includes(mode)) throw Error('Invalid phase');
const browser=await chromium.launch();
process.once('SIGTERM',async()=>{await browser.close();process.exit(1);});
try {
  for(const item of m.items) {
    const page=await browser.newPage();
    // Deliberately lagging browser clock proves server expiry cannot be bypassed.
    if(item.decision==='expired' && mode==='decide') await page.clock.install({time:new Date(item.requested-60000)});
    await page.goto(process.env.SQUIDRA_WEB_ORIGIN+'/approvals');
    await page.locator('#origin').fill(process.env.SQUIDRA_API_ORIGIN); await page.locator('#token').fill(process.env.SQUIDRA_WEB_TOKEN); await page.locator('#approval').fill(item.id);
    await page.getByRole('button',{name:'Consulter la commande'}).click();
    await expect(page.getByRole('heading',{name:'Commande à examiner'})).toBeFocused();
    await expect(page.locator('#detail')).toContainText(item.fingerprint); await expect(page.locator('#detail')).toContainText(item.digest);
    await expect(page.locator('pre')).toContainText('9007199254740993'); await expect(page.locator('#detail script')).toHaveCount(0);
    if(await page.evaluate(()=>window.compromised)!==undefined) throw Error('Evidence executed');
    if(mode==='decide') {
      const label={approved:'Autoriser',denied:'Refuser',withdrawn:'Retirer',expired:'Autoriser'}[item.decision];
      await page.getByRole('button',{name:label,exact:true}).focus(); await page.keyboard.press('Enter');
      await expect(page.getByRole('button',{name:'Annuler',exact:true})).toBeFocused();
      await page.getByRole('button',{name:'Confirmer',exact:true}).click();
      if(item.decision==='expired') { await expect(page.getByRole('alert')).toContainText('expirée ou modifiée'); await page.getByRole('button',{name:'Actualiser la demande'}).click(); }
    }
    await expect(page.getByRole('status')).toContainText({approved:'Autorisée · exécution non confirmée',denied:'Refusée',withdrawn:'Retirée',expired:'Expirée'}[item.decision]);
    await expect(page.getByRole('button',{name:'Autoriser',exact:true})).toHaveCount(0);
    await page.getByRole('button',{name:'Se déconnecter'}).click(); await expect(page.locator('#token')).toHaveValue(''); await expect(page.locator('#detail')).toBeEmpty();
    if(await page.evaluate(()=>localStorage.length+sessionStorage.length+document.cookie.length)) throw Error('Persisted browser session');
    await page.close();
  }
  const page=await browser.newPage(); await page.goto(process.env.SQUIDRA_WEB_ORIGIN+'/approvals');
  await page.locator('#origin').fill(process.env.SQUIDRA_API_ORIGIN); await page.locator('#token').fill('0'.repeat(64)); await page.locator('#approval').fill(m.items[0].id); await page.getByRole('button',{name:'Consulter la commande'}).click();
  await expect(page.getByRole('alert')).toContainText('Session refusée'); await expect(page.locator('#workspace')).toBeHidden();
  console.log('SQUIDRA_APPROVAL_LIVE_PASS:'+mode);
} finally { await browser.close(); }
