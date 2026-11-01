// Authored journal data, normal CLI and real PostgreSQL. No route interception.
import { readFile } from 'node:fs/promises';
import { chromium, expect } from '@playwright/test';
const m = JSON.parse(await readFile(process.env.SQUIDRA_WEB_MANIFEST, 'utf8'));
const mode = process.env.SQUIDRA_WEB_PHASE;
if (!['read','reload'].includes(mode)) throw Error('Invalid browser phase');
const browser = await chromium.launch();
process.once('SIGTERM',async()=>{await browser.close();process.exit(1);});
try {
  const page = await browser.newPage(), errors = [];
  page.on('pageerror',()=>errors.push('pageerror'));
  await page.goto(process.env.SQUIDRA_WEB_ORIGIN + '/timeline');
  await page.locator('#origin').fill(process.env.SQUIDRA_API_ORIGIN);
  await page.locator('#token').fill(process.env.SQUIDRA_WEB_TOKEN);
  await page.getByRole('button',{name:'Ouvrir la chronologie'}).click();
  await expect(page.locator('#query-title')).toBeFocused();
  await page.locator('#subject').fill(m.subject.toLowerCase());
  // Native datetime-local canonicalizes whole minutes without :00 seconds.
  const local = value => { const v=value.slice(0,19); return v.endsWith(':00') ? v.slice(0,16) : v; };
  for (const [field,value] of [['valid',m.valid],['from',m.from],['to',m.to],['known',m.early]]) await page.locator('#'+field).fill(local(value));
  const submit = page.getByRole('button',{name:'Afficher l’état et les changements'});
  await submit.focus(); await page.keyboard.press('Enter');
  await expect(page.getByRole('heading',{name:'État à l’instant choisi'})).toBeFocused();
  await expect(page.locator('#result > article').first()).toContainText(m.oldLocation.toLowerCase());
  await expect(page.locator('#changes-page summary')).toHaveCount(8);
  await expect(page.locator('#result')).not.toContainText('Correction tardive');
  await page.locator('#next').focus(); await page.keyboard.press('Enter');
  await expect(page.getByRole('heading',{name:'Changements dans la période'})).toBeFocused();
  await expect(page.locator('#changes-page summary')).toHaveCount(1); await expect(page.locator('#next')).toBeHidden();
  await page.locator('#known').fill(local(m.late)); await submit.click();
  await expect(page.locator('#result > article').first()).toContainText(m.newLocation.toLowerCase());
  const correction = page.locator('summary').filter({hasText:'Correction tardive'});
  await correction.focus(); await page.keyboard.press('Enter');
  const details = page.locator('details').filter({has:correction});
  await expect(details).toContainText(m.original.toLowerCase()); await expect(details).toContainText(m.correction.toLowerCase());
  await expect(details).toContainText(m.oldLocation.toLowerCase()); await expect(details).toContainText(m.newLocation.toLowerCase());
  await expect(page.getByText('Preuve précédente',{exact:true}).first()).toBeVisible();
  await expect(page.locator('#result script')).toHaveCount(0);
  if (await page.evaluate(()=>window.compromised) !== undefined) throw Error('Evidence executed');
  await page.getByRole('button',{name:'Se déconnecter'}).click();
  await expect(page.locator('#result')).toBeEmpty(); await expect(page.locator('#token')).toHaveValue('');
  if (await page.evaluate(()=>localStorage.length+sessionStorage.length+document.cookie.length) || errors.length) throw Error('Browser privacy/runtime failure');
  console.log('SQUIDRA_TIMELINE_LIVE_PASS:' + mode);
} finally { await browser.close(); }
