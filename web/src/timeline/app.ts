export {};
const el = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const input = (id: string) => el<HTMLInputElement>(id).value;
const node = (tag: string, text: string) => { const n = document.createElement(tag); n.textContent = text; return n; };
const object = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);
const uuid = (v: unknown): v is string => typeof v === 'string' && /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(v);
const str = (v: unknown, max: number): v is string => typeof v === 'string' && v.length > 0 && new TextEncoder().encode(v).length <= max;
const date = (v: unknown): v is string => typeof v === 'string' && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?Z$/.test(v) && Number.isFinite(Date.parse(v));
const sameTime = (a: unknown, b: string) => date(a) && Date.parse(a) === Date.parse(b);
const seq = (v: unknown): v is string => typeof v === 'string' && /^(0|[1-9][0-9]{0,18})$/.test(v) && BigInt(v) <= 9223372036854775807n;
const flags: Record<string, string> = { noEvidence: 'Aucune preuve', inferredEvidence: 'Preuve inférée', conflictingLocations: 'Emplacements contradictoires', projectionBehind: 'Projection en retard', priorStateUnknown: 'État précédent inconnu' };
const uncertainties = (v: unknown): v is string[] => Array.isArray(v) && v.length <= 4 && v.every(x => typeof x === 'string' && Object.hasOwn(flags, x));
type Interval = { from: string; to: string | null };
type Fact = { id: string; subjectId: string; locationId: string; frameId: string; sourceEventId: string; source: string; confidence: number; basis: string; occurredAt: string | null; observedAt: string; recordedAt: string; timeZone: string; valid: Interval; transaction: Interval };
function interval(v: unknown): v is Interval { return object(v) && date(v.from) && (v.to === null || date(v.to) && Date.parse(v.to) > Date.parse(v.from)); }
function fact(v: unknown): v is Fact { return object(v) && ['id','subjectId','locationId','frameId','sourceEventId'].every(k => uuid(v[k])) && v.id === v.sourceEventId && str(v.source, 256) && typeof v.confidence === 'number' && v.confidence >= 0 && v.confidence <= 1 && ['observed','inferred'].includes(String(v.basis)) && (v.occurredAt === null || date(v.occurredAt)) && date(v.observedAt) && date(v.recordedAt) && str(v.timeZone,128) && interval(v.valid) && interval(v.transaction); }
function facts(v: unknown, subject: string): v is Fact[] { return Array.isArray(v) && v.length <= 32 && v.every(x => fact(x) && x.subjectId.toLowerCase() === subject) && new Set(v.map(x => x.id)).size === v.length; }
type Query = { subject: string; valid: string; known: string; from: string; to: string };
type Change = { id: string; subjectId: string; kind: string; effectiveAt: string; currentFactId: string; previousFactIds: string[]; supportingEventIds: string[]; uncertainty: string[] };
type Page = { actorId: string; facts: Fact[]; changes: Change[]; next: string | null; projectedThroughSequence: string; availableThroughSequence: string; projectionBehind: boolean };
function fail(): never { throw Error('Réponse temporelle invalide.'); }
function decodePage(v: unknown, q: Query, actor: string, previous?: Page): Page {
  if (!object(v) || v.schemaVersion !== '1' || v.actorId !== actor || v.subjectId !== q.subject || v.locationId !== null || !sameTime(v.from,q.from) || !sameTime(v.to,q.to) || !sameTime(v.knownAt,q.known) || !facts(v.facts,q.subject) || !seq(v.projectedThroughSequence) || !seq(v.availableThroughSequence) || BigInt(v.availableThroughSequence) < BigInt(v.projectedThroughSequence) || v.projectionBehind !== (BigInt(v.availableThroughSequence) > BigInt(v.projectedThroughSequence)) || !(v.next === null || str(v.next,2048)) || !Array.isArray(v.changes) || v.changes.length > 8) fail();
  const all = new Map(v.facts.map(f => [f.id, f]));
  for (const c of v.changes) {
    if (!object(c) || !uuid(c.id) || c.id !== c.currentFactId || c.subjectId !== q.subject || !['observation','location_changed','correction'].includes(String(c.kind)) || !date(c.effectiveAt) || Date.parse(c.effectiveAt) < Date.parse(q.from) || Date.parse(c.effectiveAt) >= Date.parse(q.to) || !all.has(c.id) || !Array.isArray(c.previousFactIds) || c.previousFactIds.length > 32 || !c.previousFactIds.every(id => uuid(id) && all.has(id)) || !Array.isArray(c.supportingEventIds) || c.supportingEventIds.length > 33 || !c.supportingEventIds.every(uuid) || !uncertainties(c.uncertainty)) fail();
  }
  if (previous && (previous.projectedThroughSequence !== v.projectedThroughSequence || previous.availableThroughSequence !== v.availableThroughSequence || previous.next === v.next)) fail();
  if (v.next !== null && !v.changes.length) fail();
  return v as Page;
}
let session: { origin: string; token: string } | undefined, active: AbortController | undefined, epoch = 0;
let selected: Query | undefined, page: Page | undefined, actor = '';
el('local-help').textContent = 'HTTP sur localhost ou 127.0.0.1. Origine UI à autoriser : ' + location.origin;
function clear() { selected = undefined; page = undefined; el('result').replaceChildren(); el('next').hidden = true; }
function logout() { epoch++; active?.abort(); session = undefined; actor = ''; clear(); el<HTMLInputElement>('token').value = ''; el('workspace').hidden = true; el('connection').hidden = false; el('logout').hidden = true; el('status').textContent = 'Session fermée.'; el('error').hidden = true; el('origin').focus(); }
async function request(path: string, body: object, signal: AbortSignal): Promise<unknown> {
  if (!session) throw Error('Connectez-vous au serveur.');
  const response = await fetch(session.origin + '/api/v1/world/' + path, { method:'POST', body:JSON.stringify(body), headers:{Authorization:'Bearer ' + session.token,'Content-Type':'application/json'}, credentials:'omit', redirect:'error', cache:'no-store', referrerPolicy:'no-referrer', signal });
  if (response.status === 401) { logout(); el('error').textContent = 'Session refusée. Vérifiez le jeton.'; el('error').hidden = false; throw Error('Session refusée.'); }
  if (!response.ok) throw Error(`Lecture indisponible (${response.status}). Réessayez ; aucun état confirmé.`);
  if (!response.headers.get('Content-Type')?.startsWith('application/json') || !response.body) fail();
  const reader = response.body.getReader(), chunks: Uint8Array[] = []; let size = 0;
  while (true) { const item = await reader.read(); if (item.done) break; size += item.value.length; if (size > 131072) { await reader.cancel(); fail(); } chunks.push(item.value); }
  const bytes = new Uint8Array(size); let offset = 0; for (const chunk of chunks) { bytes.set(chunk,offset); offset += chunk.length; }
  return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes)) as unknown;
}
async function perform(work: (signal: AbortSignal, generation: number) => Promise<void>) {
  active?.abort(); const generation = ++epoch, controller = new AbortController(); active = controller;
  const timer = setTimeout(() => controller.abort(),10000); el('error').hidden = true; el('status').textContent = 'Lecture en cours…'; el('next').hidden = true;
  try { await work(controller.signal,generation); }
  catch (cause) { if (generation !== epoch) return; clear(); el('status').textContent = ''; el('error').textContent = cause instanceof Error && !['TypeError','AbortError','SyntaxError'].includes(cause.name) ? cause.message : 'Lecture interrompue ou réponse invalide. Réessayez.'; el('error').hidden = false; }
  finally { clearTimeout(timer); if (active === controller) active = undefined; }
}
function evidence(f: Fact) {
  const block = document.createElement('article'); block.className = 'card';
  block.append(node('h3','Emplacement : ' + f.locationId), node('p',`${f.basis === 'observed' ? 'Observé' : 'Inféré'} · confiance déclarée ${f.confidence}`), node('p','Source : ' + f.source), node('p','Événement : ' + f.sourceEventId), node('p','Repère spatial : ' + f.frameId), node('p',`Validité : ${f.valid.from} → ${f.valid.to ?? 'ouverte'}`), node('p',`Connu : ${f.transaction.from} → ${f.transaction.to ?? 'ouverte'}`), node('p',`Observé ${f.observedAt} · enregistré ${f.recordedAt} · fuseau ${f.timeZone}`)); return block;
}
function renderPage(value: Page) {
  document.getElementById('changes-page')?.remove();
  const section = document.createElement('section'), title = node('h2','Changements dans la période'); title.tabIndex = -1; section.id = 'changes-page'; section.append(title);
  if (value.projectionBehind) section.append(node('p',flags.projectionBehind!));
  if (!value.changes.length) section.append(node('p','Aucun changement connu dans cette période.'));
  for (const c of value.changes) {
    const details = document.createElement('details'); details.append(node('summary',`${c.effectiveAt} · ${{observation:'Observation',location_changed:'Changement de lieu',correction:'Correction tardive'}[c.kind]}`),node('p',c.uncertainty.map(f => flags[f]).join(' · ')),node('p','Événements justificatifs : ' + c.supportingEventIds.join(', ')));
    for (const id of [c.currentFactId,...c.previousFactIds]) { details.append(node('p',id === c.currentFactId ? 'Preuve actuelle' : 'Preuve précédente'),evidence(value.facts.find(f => f.id === id)!)); }
    section.append(details);
  }
  el('result').append(section); el('next').hidden = value.next === null; el('status').textContent = `${value.changes.length} changement(s) dans cette page.`; return title;
}
function changes(q: Query, signal: AbortSignal, cursor?: string) { return request('changes',{schemaVersion:'1',subjectId:q.subject,from:q.from,to:q.to,knownAt:q.known,limit:8,...(cursor ? {cursor} : {})},signal); }
el('login').addEventListener('submit',event => { event.preventDefault(); try {
  const origin = new URL(input('origin')), token = input('token');
  if (origin.protocol !== 'http:' || !['localhost','127.0.0.1'].includes(origin.hostname) || origin.username || origin.password || origin.pathname !== '/' || origin.search || origin.hash || !/^[a-f0-9]{64}$/.test(token)) throw Error('Adresse HTTP locale et jeton hexadécimal de 64 caractères requis.');
  session = {origin:origin.origin,token}; el<HTMLInputElement>('token').value = ''; el('connection').hidden = true; el('workspace').hidden = false; el('logout').hidden = false; el('error').hidden = true; el('status').textContent = 'Session locale prête. Lancez une lecture pour vérifier son accès.';
  const now = new Date(); for (const id of ['valid','known','to']) el<HTMLInputElement>(id).value = now.toISOString().slice(0,19); el<HTMLInputElement>('from').value = new Date(now.getTime()-86400000).toISOString().slice(0,19); el('query-title').focus();
} catch { el('error').textContent = 'Adresse HTTP locale et jeton hexadécimal de 64 caractères requis.'; el('error').hidden = false; } });
el('query').addEventListener('submit',event => { event.preventDefault(); clear(); void perform(async (signal,generation) => {
  const utc = (id: string) => { const raw = input(id); const value = raw.length === 16 ? raw + ':00Z' : raw + 'Z'; if (!date(value)) throw Error('Dates UTC invalides.'); return value; };
  const q: Query = {subject:input('subject').trim().toLowerCase(),valid:utc('valid'),known:utc('known'),from:utc('from'),to:utc('to')};
  if (!uuid(q.subject) || Date.parse(q.from) >= Date.parse(q.to)) throw Error('Entité UUID et période croissante requises.');
  const v = await request('location',{schemaVersion:'1',entityId:q.subject,validAt:q.valid,knownAt:q.known},signal);
  if (generation !== epoch) return;
  if (!object(v) || v.schemaVersion !== '1' || !uuid(v.actorId) || v.entityId !== q.subject || !sameTime(v.validAt,q.valid) || !sameTime(v.knownAt,q.known) || !facts(v.facts,q.subject) || !uncertainties(v.uncertainty) || !['evidence','no_evidence','not_found'].includes(String(v.status)) || (v.status === 'evidence') !== (v.facts.length > 0)) fail();
  if (v.status === 'not_found' ? v.projectedThroughSequence !== null || v.availableThroughSequence !== null : !seq(v.projectedThroughSequence) || !seq(v.availableThroughSequence) || BigInt(v.projectedThroughSequence) > BigInt(v.availableThroughSequence)) fail();
  const result = decodePage(await changes(q,signal),q,v.actorId); if (generation !== epoch) return;
  actor = v.actorId; selected = q; page = result;
  const title = node('h2','État à l’instant choisi'); title.tabIndex = -1;
  el('result').append(title,node('p',`Instant ${q.valid} · connaissance ${q.known}`),node('p',v.status === 'not_found' ? 'Entité absente ou inaccessible.' : v.status === 'no_evidence' ? 'Aucune preuve disponible.' : 'État étayé par les preuves suivantes.'),node('p',v.uncertainty.map(f => flags[f]).join(' · ')),...v.facts.map(evidence));
  renderPage(result); title.focus();
}); });
el('next').addEventListener('click',() => { const q = selected, previous = page; if (!q || !previous?.next) return; void perform(async (signal,generation) => { const result = decodePage(await changes(q,signal,previous.next!),q,actor,previous); if (generation !== epoch) return; page = result; renderPage(result).focus(); }); });
el('query').addEventListener('input',() => { epoch++; active?.abort(); clear(); el('status').textContent = 'Dates modifiées. Relancez la lecture.'; });
el('logout').addEventListener('click',logout); window.addEventListener('pagehide',logout);
