// Real browser/API/SQL integration. No request interception or mocked responses.
import { readFile } from 'node:fs/promises';
import { chromium, expect } from '@playwright/test';
const manifest = JSON.parse(await readFile(process.env.SQUIDRA_WEB_MANIFEST, 'utf8'));
const mode = process.env.SQUIDRA_WEB_PHASE;
if (!['decide', 'reload'].includes(mode)) throw Error('Invalid browser phase');
const browser = await chromium.launch();
process.once('SIGTERM', async () => { await browser.close(); process.exit(1); });
try {
  const page = await browser.newPage();
  const failures = []; page.on('pageerror', () => failures.push('pageerror'));
  async function open(journal, token = process.env.SQUIDRA_WEB_TOKEN) {
    await page.goto(process.env.SQUIDRA_WEB_ORIGIN);
    await page.getByLabel('Adresse du serveur').fill(process.env.SQUIDRA_API_ORIGIN);
    await page.getByLabel('Jeton de session').fill(token);
    await page.getByLabel('Identifiant du journal').fill(journal);
    await page.getByRole('button', { name: 'Consulter les propositions' }).click();
  }
  await open(manifest.journal);
  await expect(page.getByRole('heading', { name: 'Propositions du journal' })).toBeFocused();
  await page.getByRole('button', { name: /key.color/ }).click();
  await expect(page.getByRole('heading', { name: 'key.color', exact: true })).toBeFocused();
  await expect(page.getByText('Sources : ' + manifest.source, { exact: true })).toBeVisible();
  await page.getByText('Texte original · ' + manifest.memory).click();
  await expect(page.getByText('The key was red. The key was blue. <script>window.compromised=true</script>', { exact: true })).toBeVisible();
  await expect(page.locator('#detail script')).toHaveCount(0);
  if (mode === 'decide') {
    await page.getByRole('button', { name: 'Approuver', exact: true }).click();
    await expect(page.getByRole('button', { name: 'Annuler' })).toBeFocused();
    await page.getByRole('button', { name: 'Confirmer', exact: true }).click();
    await expect(page.getByRole('status')).toHaveText('Décision enregistrée par le serveur.');
  }
  await expect(page.getByRole('button', { name: /key.color — Approuvée/ })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Approuver', exact: true })).toHaveCount(0);
  await expect(page.getByText(new RegExp('Décision enregistrée par ' + manifest.actor))).toBeVisible();
  await open(manifest.rejectedJournal); await page.getByRole('button', { name: /key.color/ }).click();
  if (mode === 'decide') {
    await page.getByRole('button', { name: 'Rejeter', exact: true }).click(); await page.getByRole('button', { name: 'Confirmer', exact: true }).click();
    await expect(page.getByRole('status')).toHaveText('Décision enregistrée par le serveur.');
  }
  await expect(page.getByRole('button', { name: /key.color — Rejetée/ })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Approuver', exact: true })).toHaveCount(0);
  await open(manifest.conflictedJournal);
  await page.getByRole('button', { name: /key.color — Contradiction/ }).first().click();
  await expect(page.getByText(/^Contradictions :/)).toBeVisible();
  await expect(page.getByRole('button', { name: 'Approuver', exact: true })).toHaveCount(0);
  await page.getByRole('button', { name: 'Se déconnecter' }).click();
  await expect(page.getByLabel('Jeton de session')).toHaveValue('');
  const storage = await page.evaluate(() => localStorage.length + sessionStorage.length + document.cookie.length);
  if (storage !== 0 || failures.length) throw Error('Browser state/privacy check failed');
  await open(manifest.journal, '0'.repeat(64));
  await expect(page.getByRole('alert')).toContainText('Session refusée');
  await expect(page.locator('#workspace')).toBeHidden();
  console.log('SQUIDRA_WEB_LIVE_PASS:' + mode);
} finally { await browser.close(); }
