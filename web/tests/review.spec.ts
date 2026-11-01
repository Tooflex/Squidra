import { test, expect, type Page } from '@playwright/test';
const journal = '10000000-0000-0000-0000-000000000001', proposal = '20000000-0000-0000-0000-000000000002', subject = '30000000-0000-0000-0000-000000000003', memory = '40000000-0000-0000-0000-000000000004';
const token = 'a'.repeat(64); // Authored public fixture; never a user credential.
const summary = () => ({ id: proposal, subjectId: subject, version: 0, predicate: 'key.color', critical: true, state: 'pending' });
const preview = () => ({ schemaVersion: '1', journalId: journal, journalVersion: 1, proposal: summary(), value: 'red', validFrom: '1970-01-01T00:00:00.000000Z', sourceIds: [memory], conflictingProposalIds: [], evidence: [{ memoryId: memory, sourceIds: [memory], quotation: '<script>window.compromised=true</script>', originalText: 'Original source <img src=x onerror="window.compromised=true">' }] });
async function login(page: Page) {
  await page.goto('/'); await page.getByLabel('Jeton de session').fill(token); await page.getByLabel('Identifiant du journal').fill(journal); await page.getByRole('button', { name: 'Consulter les propositions' }).click();
}
async function fixture(page: Page, decisionStatus = 200) {
  const posts: unknown[] = [], headers: string[] = []; let value = preview();
  await page.route('http://127.0.0.1:8080/**', async route => {
    headers.push(route.request().headers()['authorization'] ?? '');
    if (route.request().method() === 'POST') {
      posts.push(route.request().postDataJSON());
      if (decisionStatus !== 200) { await route.fulfill({ status: decisionStatus, json: {} }); return; }
      value = { ...value, journalVersion: 2, proposal: { ...value.proposal, version: 1, state: route.request().postDataJSON().decision } };
      await route.fulfill({ json: { ...value, reviewerId: subject, reviewedAt: '2026-11-01T10:00:00.000000Z' } }); return;
    }
    await route.fulfill({ json: route.request().url().includes('/proposals/') ? value : { schemaVersion: '1', journalId: journal, journalVersion: value.journalVersion, proposals: [value.proposal] } });
  });
  return { posts, headers };
}
test('keyboard review preserves exact versions and renders hostile evidence as text', async ({ page }) => {
  const mock = await fixture(page); await login(page);
  await expect(page.getByRole('heading', { name: 'Propositions du journal' })).toBeFocused();
  const item = page.getByRole('button', { name: /key.color/ }); await item.focus(); await page.keyboard.press('Enter');
  await expect(page.getByRole('heading', { name: 'key.color', exact: true })).toBeFocused();
  await expect(page.getByText('<script>window.compromised=true</script>', { exact: true })).toBeVisible();
  await page.getByText('Texte original · ' + memory).click();
  expect(await page.evaluate(() => (window as unknown as { compromised?: boolean }).compromised)).toBeUndefined();
  await expect(page.locator('#detail img, #detail script')).toHaveCount(0);
  await page.getByRole('button', { name: 'Approuver', exact: true }).focus(); await page.keyboard.press('Enter');
  await expect(page.getByRole('button', { name: 'Annuler' })).toBeFocused(); await page.keyboard.press('Escape');
  expect(mock.posts).toHaveLength(0);
  await page.getByRole('button', { name: 'Approuver', exact: true }).click(); await page.getByRole('button', { name: 'Confirmer', exact: true }).click();
  await expect(page.getByRole('status')).toHaveText('Décision enregistrée par le serveur.');
  expect(mock.posts).toEqual([{ schemaVersion: '1', journalVersion: '1', proposalVersion: '0', decision: 'approved' }]);
  expect(mock.headers.every(v => v === 'Bearer ' + token)).toBeTruthy();
  await expect(page.getByRole('button', { name: 'Approuver', exact: true })).toHaveCount(0);
  await expect(page.getByRole('button', { name: /key.color — Approuvée/ })).toBeVisible();
  await expect(page.locator('#journal-info')).toContainText('version 2');
  await page.screenshot({ path: 'test-results/review.png', fullPage: true });
});
test('rejection is explicit and logout clears credentials without browser storage', async ({ page }) => {
  const mock = await fixture(page); await login(page); await page.getByRole('button', { name: /key.color/ }).click();
  await page.getByRole('button', { name: 'Rejeter', exact: true }).click(); await page.getByRole('button', { name: 'Confirmer', exact: true }).click();
  await expect(page.getByRole('status')).toContainText('enregistrée'); expect((mock.posts[0] as { decision: string }).decision).toBe('rejected');
  expect(await page.evaluate(() => [localStorage.length, sessionStorage.length, document.cookie])).toEqual([0, 0, '']);
  await page.getByRole('button', { name: 'Se déconnecter' }).click(); await expect(page.getByLabel('Jeton de session')).toHaveValue('');
  await expect(page.locator('#workspace')).toBeHidden(); expect(page.url()).not.toContain(token);
});
test('stale decisions show conflict and remove decision controls', async ({ page }) => {
  await fixture(page, 409); await login(page); await page.getByRole('button', { name: /key.color/ }).click();
  await page.getByRole('button', { name: 'Approuver', exact: true }).click(); await page.getByRole('button', { name: 'Confirmer', exact: true }).click();
  await expect(page.getByRole('alert')).toContainText('Actualisez'); await expect(page.getByRole('button', { name: 'Approuver', exact: true })).toHaveCount(0);
  await expect(page.getByRole('status')).not.toContainText('enregistrée');
});
test('unavailability and malformed data never become empty or approved results', async ({ page }) => {
  await page.route('http://127.0.0.1:8080/**', route => route.fulfill({ status: 503, json: {} })); await login(page);
  await expect(page.getByRole('alert')).toContainText('indisponible'); await expect(page.locator('#workspace')).toBeHidden();
  await page.unrouteAll(); await page.route('http://127.0.0.1:8080/**', route => route.fulfill({ json: { schemaVersion: '1', journalId: journal, journalVersion: 1, proposals: [{ ...summary(), critical: 'false' }] } }));
  await page.getByLabel('Jeton de session').fill(token); await page.getByRole('button', { name: 'Consulter les propositions' }).click();
  await expect(page.getByRole('alert')).toContainText('invalide'); await expect(page.locator('#workspace')).toBeHidden();
});
test('off-host destinations are refused before a credential request', async ({ page }) => {
  let requests = 0; await page.route('https://example.com/**', route => { requests++; return route.abort(); });
  await page.goto('/'); await page.getByLabel('Adresse du serveur').fill('https://example.com'); await page.getByLabel('Jeton de session').fill(token); await page.getByLabel('Identifiant du journal').fill(journal); await page.getByRole('button', { name: 'Consulter les propositions' }).click();
  await expect(page.getByRole('alert')).toContainText('adresse HTTP locale'); expect(requests).toBe(0);
});
test('logout prevents a late preview from reopening the session', async ({ page }) => {
  await fixture(page); await login(page);
  let release!: () => void, entered!: () => void, finished!: () => void;
  const started = new Promise<void>(resolve => { entered = resolve; }), done = new Promise<void>(resolve => { finished = resolve; });
  await page.route('**/proposals/*', async route => { entered(); await new Promise<void>(resolve => { release = resolve; }); try { await route.fulfill({ json: preview() }); } catch {} finally { finished(); } });
  await page.getByRole('button', { name: /key.color/ }).click(); await started; await page.getByRole('button', { name: 'Se déconnecter' }).click(); release(); await done;
  await page.evaluate(() => new Promise(requestAnimationFrame));
  await expect(page.locator('#workspace')).toBeHidden(); await expect(page.getByLabel('Jeton de session')).toHaveValue('');
});
