export {};
type State = 'pending' | 'approved' | 'rejected' | 'conflicted';
type Summary = { id: string; subjectId: string; version: number; predicate: string; critical: boolean; state: State };
type Index = { journalId: string; journalVersion: number; proposals: Summary[] };
type Evidence = { memoryId: string; sourceIds: string[]; quotation: string; originalText: string };
type Preview = { journalId: string; journalVersion: number; proposal: Summary; value: string; validFrom: string; validUntil?: string; sourceIds: string[]; conflictingProposalIds: string[]; evidence: Evidence[]; reviewerId?: string; reviewedAt?: string };
const element = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const labels: Record<State, string> = { pending: 'À examiner', approved: 'Approuvée · privée', rejected: 'Rejetée', conflicted: 'Contradiction à résoudre' };
const uuid = (value: unknown): value is string => typeof value === 'string' && /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value);
const version = (value: unknown) => Number.isInteger(value) && Number(value) >= 0 && Number(value) <= 512;
const record = (value: unknown): value is Record<string, unknown> => !!value && typeof value === 'object' && !Array.isArray(value);
const text = (value: unknown, limit: number): value is string => typeof value === 'string' && new TextEncoder().encode(value).length <= limit;
const ids = (value: unknown, limit: number) => Array.isArray(value) && value.length <= limit && value.every(uuid);
const summary = (value: unknown): value is Summary => record(value) && uuid(value.id) && uuid(value.subjectId) && version(value.version) && text(value.predicate, 64) && typeof value.critical === 'boolean' && typeof value.state === 'string' && Object.hasOwn(labels, value.state);
function decode(value: unknown, detail: boolean): Index | Preview {
  if (!record(value) || value.schemaVersion !== '1' || !uuid(value.journalId) || !version(value.journalVersion)) throw Error('Réponse du serveur invalide.');
  if (!detail) {
    if (!Array.isArray(value.proposals) || value.proposals.length > 256 || !value.proposals.every(summary)) throw Error('Liste de propositions invalide.');
    return value as Index;
  }
  if (!summary(value.proposal) || !text(value.value, 2048) || !text(value.validFrom, 35) || (value.validUntil !== undefined && !text(value.validUntil, 35)) || !ids(value.sourceIds, 16) || !ids(value.conflictingProposalIds, 255) || !Array.isArray(value.evidence) || value.evidence.length > 16 || !value.evidence.every(e => record(e) && uuid(e.memoryId) && ids(e.sourceIds, 16) && text(e.quotation, 2048) && text(e.originalText, 8192)) || (value.reviewerId !== undefined && !uuid(value.reviewerId)) || (value.reviewedAt !== undefined && !text(value.reviewedAt, 35))) throw Error('Détail de proposition invalide.');
  return value as Preview;
}
let session: { origin: string; token: string; journal: string } | undefined;
let epoch = 0, active: AbortController | undefined, current: Preview | undefined, decision: 'approved' | 'rejected' = 'approved';
const dialog = element<HTMLDialogElement>('confirm');
element('local-help').textContent = 'Serveur HTTP sur localhost ou 127.0.0.1 uniquement. Configurez son origine UI sur ' + location.origin + '.';
function node<K extends keyof HTMLElementTagNameMap>(tag: K, content: string, className?: string) {
  const value = document.createElement(tag); value.textContent = content; if (className) value.className = className; return value;
}
function status(message: string) { element('status').textContent = message; }
function error(message = '') { element('error').textContent = message; element('error').hidden = !message; }
function disconnect() {
  epoch++; active?.abort(); session = undefined; current = undefined; dialog.close();
  element<HTMLInputElement>('token').value = ''; element('workspace').hidden = true; element('connection').hidden = false; element('logout').hidden = true;
  element('proposals').replaceChildren(); element('detail').replaceChildren(); status('Session fermée.'); error(); element('origin').focus();
}
class HTTPFailure extends Error { constructor(readonly code: number) { super(({ 401: 'Session refusée. Vérifiez le jeton.', 403: 'Accès refusé. Vérifiez aussi l’origine UI du serveur.', 404: 'Journal ou proposition introuvable.', 409: 'La proposition a changé ou ne peut plus être validée. Actualisez avant toute nouvelle décision.', 503: 'Service indisponible. Aucune décision confirmée.' } as Record<number, string>)[code] ?? `Erreur du serveur (${code}).`); } }
async function request(path: string, body?: object): Promise<unknown> {
  const context = session; if (!context) throw Error('Connectez-vous au serveur.');
  active?.abort(); const controller = new AbortController(); active = controller;
  const timeout = window.setTimeout(() => controller.abort(), 10000);
  try {
    const response = await fetch(context.origin + path, { method: body ? 'POST' : 'GET', headers: { Authorization: 'Bearer ' + context.token, ...(body ? { 'Content-Type': 'application/json' } : {}) }, body: body ? JSON.stringify(body) : undefined, signal: controller.signal, cache: 'no-store', credentials: 'omit', redirect: 'error', referrerPolicy: 'no-referrer' });
    if (!response.ok) throw new HTTPFailure(response.status);
    if (!response.headers.get('Content-Type')?.startsWith('application/json') || !response.body) throw Error('Réponse du serveur invalide.');
    const reader = response.body.getReader(), chunks: Uint8Array[] = []; let size = 0;
    while (true) { const item = await reader.read(); if (item.done) break; size += item.value.length; if (size > 1048576) { await reader.cancel(); throw Error('Réponse trop volumineuse.'); } chunks.push(item.value); }
    const bytes = new Uint8Array(size); let offset = 0; for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)) as unknown;
  } finally { clearTimeout(timeout); if (active === controller) active = undefined; }
}
async function perform(work: () => Promise<void>) {
  const generation = ++epoch; error();
  try { await work(); }
  catch (cause) {
    if (generation !== epoch) return;
    current = undefined; dialog.close(); element('detail').replaceChildren(node('p', 'Rechargez les données avant de prendre une décision.'));
    status(''); if (cause instanceof HTTPFailure && cause.code === 401) disconnect();
    error(cause instanceof HTTPFailure ? cause.message : cause instanceof Error && cause.name !== 'TypeError' && cause.name !== 'AbortError' ? cause.message : 'Connexion interrompue ou délai dépassé. Vérifiez le serveur puis actualisez.');
  }
}
function base() { return '/api/v1/consolidations/' + session!.journal; }
async function loadIndex() {
  const generation = epoch, result = decode(await request(base()), false) as Index;
  if (generation !== epoch) return;
  if (result.journalId.toLowerCase() !== session?.journal.toLowerCase()) throw Error('Réponse hors du journal demandé.');
  current = undefined; element('connection').hidden = true; element('workspace').hidden = false; element('logout').hidden = false;
  element('journal-info').textContent = `Journal ${result.journalId} · version ${result.journalVersion}`;
  const list = element('proposals'); list.replaceChildren(); element('detail').replaceChildren(node('p', 'Sélectionnez une proposition pour examiner ses sources.'));
  for (const item of result.proposals) { const li = document.createElement('li'), button = node('button', `${item.predicate} — ${labels[item.state]}${item.critical ? ' · critique' : ''}`); button.dataset.id = item.id; button.addEventListener('click', () => void perform(() => loadPreview(item.id))); li.append(button); list.append(li); }
  status(result.proposals.length ? `${result.proposals.length} proposition(s) chargée(s).` : 'Aucune proposition dans ce journal.'); element('list-title').focus();
}
async function loadPreview(id: string) {
  const generation = epoch, result = decode(await request(base() + '/proposals/' + id), true) as Preview;
  if (generation !== epoch) return;
  if (result.journalId.toLowerCase() !== session?.journal.toLowerCase() || result.proposal.id !== id) throw Error('Réponse hors de la proposition demandée.');
  render(result);
}
function render(value: Preview) {
  current = value; element('journal-info').textContent = `Journal ${value.journalId} · version ${value.journalVersion}`; const target = element('detail'); target.replaceChildren();
  const title = node('h2', value.proposal.predicate); title.tabIndex = -1; target.append(title, node('p', labels[value.proposal.state] + (value.proposal.critical ? ' · Donnée critique' : ''), 'eyebrow'), node('p', value.value), node('p', `Sujet : ${value.proposal.subjectId}`, 'meta'), node('p', `Validité : ${value.validFrom} → ${value.validUntil ?? 'sans fin connue'}`, 'meta'));
  if (value.conflictingProposalIds.length) target.append(node('p', 'Contradictions : ' + value.conflictingProposalIds.join(', ')));
  target.append(node('h3', 'Sources à examiner'));
  for (const source of value.evidence) { const details = document.createElement('details'); details.append(node('summary', 'Texte original · ' + source.memoryId), node('p', source.originalText)); target.append(node('blockquote', source.quotation), node('p', 'Sources : ' + source.sourceIds.join(', '), 'meta'), details); }
  if (value.reviewerId) target.append(node('p', `Décision enregistrée par ${value.reviewerId} · ${value.reviewedAt ?? 'date inconnue'}`, 'meta'));
  if (value.proposal.state === 'pending' && value.conflictingProposalIds.length === 0) {
    const actions = document.createElement('div'); actions.className = 'actions';
    for (const choice of ['rejected', 'approved'] as const) { const button = node('button', choice === 'approved' ? 'Approuver' : 'Rejeter'); button.addEventListener('click', () => { decision = choice; element('confirm-text').textContent = `${choice === 'approved' ? 'Approuver' : 'Rejeter'} « ${value.proposal.predicate} = ${value.value} » ? Journal version ${value.journalVersion}, proposition version ${value.proposal.version}.`; dialog.showModal(); element('cancel').focus(); }); actions.append(button); }
    target.append(actions);
  }
  for (const button of document.querySelectorAll<HTMLButtonElement>('#proposals button')) {
    button.setAttribute('aria-current', String(button.dataset.id === value.proposal.id));
    if (button.dataset.id === value.proposal.id) button.textContent = `${value.proposal.predicate} — ${labels[value.proposal.state]}${value.proposal.critical ? ' · critique' : ''}`;
  }
  status('Proposition chargée. Vérifiez les sources avant de décider.'); title.focus();
}
element('login').addEventListener('submit', event => {
  event.preventDefault(); void perform(async () => {
    const origin = new URL(element<HTMLInputElement>('origin').value), token = element<HTMLInputElement>('token').value, journal = element<HTMLInputElement>('journal').value.trim();
    if (origin.protocol !== 'http:' || !['127.0.0.1', 'localhost'].includes(origin.hostname) || origin.username || origin.password || origin.pathname !== '/' || origin.search || origin.hash) throw Error('Utilisez uniquement une adresse HTTP locale, sans chemin ni identifiants.');
    if (!/^[a-f0-9]{64}$/.test(token) || !uuid(journal)) throw Error('Vérifiez le jeton hexadécimal et l’identifiant UUID du journal.');
    session = { origin: origin.origin, token, journal }; element<HTMLInputElement>('token').value = ''; element('logout').hidden = false; await loadIndex();
  });
});
element('logout').addEventListener('click', disconnect);
element('reload').addEventListener('click', () => void perform(loadIndex));
element('cancel').addEventListener('click', () => dialog.close());
element('commit').addEventListener('click', () => {
  const preview = current, chosen = decision; if (!preview) return; dialog.close(); current = undefined;
  element('detail').replaceChildren(node('p', 'Enregistrement de la décision…'));
  void perform(async () => {
    const generation = epoch, result = decode(await request(base() + '/proposals/' + preview.proposal.id + '/decision', { schemaVersion: '1', journalVersion: String(preview.journalVersion), proposalVersion: String(preview.proposal.version), decision: chosen }), true) as Preview;
    if (generation !== epoch) return;
    if (result.journalId !== preview.journalId || result.proposal.id !== preview.proposal.id || result.proposal.state !== chosen || result.journalVersion !== preview.journalVersion + 1 || result.proposal.version !== preview.proposal.version + 1 || !result.reviewerId || !result.reviewedAt) throw Error('Décision retournée pour une autre proposition.');
    render(result); status('Décision enregistrée par le serveur.');
  });
});
window.addEventListener('pagehide', disconnect);
