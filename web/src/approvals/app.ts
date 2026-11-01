export {};
type Decision = 'pending' | 'approved' | 'denied' | 'expired' | 'withdrawn';
type Choice = 'approved' | 'denied' | 'withdrawn';
type Preview = { schemaVersion: string; id: string; runId: string; ledgerId: string; decision: Decision; version: number; digest: string; commandFingerprint: string; tool: string; target: string; argumentsJSON: string; scope: string[]; requestedAt: string; expiresAt: string; decidedAt?: string };
const el = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const node = (tag: string, content: string) => { const n = document.createElement(tag); n.textContent = content; return n; };
const uuid = (v: unknown): v is string => typeof v === 'string' && /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(v);
const text = (v: unknown, limit: number): v is string => typeof v === 'string' && v.length > 0 && new TextEncoder().encode(v).length <= limit;
const hash = (v: unknown) => typeof v === 'string' && /^[a-f0-9]{64}$/.test(v);
const date = (v: unknown): v is string => typeof v === 'string' && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/.test(v) && Number.isFinite(Date.parse(v));
const labels: Record<Decision,string> = { pending:'En attente', approved:'Autorisée · exécution non confirmée', denied:'Refusée', expired:'Expirée', withdrawn:'Retirée' };
function decode(v: unknown): Preview {
  if (!v || typeof v !== 'object' || Array.isArray(v)) throw Error('Réponse de demande invalide.');
  const p = v as Record<string,unknown>;
  if (p.schemaVersion !== '1' || !uuid(p.id) || !uuid(p.runId) || !uuid(p.ledgerId) || !Number.isSafeInteger(p.version) || Number(p.version) < 0 || typeof p.decision !== 'string' || !Object.hasOwn(labels,p.decision) || !hash(p.digest) || !hash(p.commandFingerprint) || !text(p.tool,256) || !text(p.target,2048) || !text(p.argumentsJSON,65536) || !Array.isArray(p.scope) || p.scope.length > 64 || !p.scope.every(v=>text(v,256)) || !date(p.requestedAt) || !date(p.expiresAt) || Date.parse(p.expiresAt) <= Date.parse(p.requestedAt) || (p.decidedAt !== undefined && !date(p.decidedAt))) throw Error('Réponse de demande invalide.');
  try { JSON.parse(p.argumentsJSON); } catch { throw Error('Arguments JSON invalides.'); }
  return p as Preview;
}
let session: {origin:string; token:string; id:string} | undefined, current: Preview | undefined, epoch = 0, active: AbortController | undefined, choice: Choice = 'denied', expiryTimer: number | undefined;
const dialog = el<HTMLDialogElement>('confirm');
el('local-help').textContent = 'HTTP sur localhost ou 127.0.0.1 uniquement. Origine UI : ' + location.origin;
function clear() { current = undefined; clearTimeout(expiryTimer); dialog.close(); el('detail').replaceChildren(); }
function disconnect() { epoch++; active?.abort(); session = undefined; clear(); el<HTMLInputElement>('token').value = ''; el('workspace').hidden = true; el('connection').hidden = false; el('logout').hidden = true; el('error').hidden = true; el('status').textContent = 'Session fermée.'; el('origin').focus(); }
class HTTPFailure extends Error { constructor(readonly code: number) { super(({401:'Session refusée. Vérifiez le jeton.',403:'Accès refusé.',404:'Demande absente ou inaccessible.',409:'Demande expirée ou modifiée. Actualisez avant toute décision.',503:'Service indisponible. Aucune décision confirmée.'} as Record<number,string>)[code] ?? `Erreur du serveur (${code}).`); } }
async function request(body?: object): Promise<unknown> {
  if (!session) throw Error('Connectez-vous au serveur.');
  active?.abort(); const controller = new AbortController(); active = controller; const timer = setTimeout(()=>controller.abort(),10000);
  try {
    const response = await fetch(session.origin+'/api/v1/approvals/'+session.id+(body ? '/decision' : ''),{method:body ? 'POST' : 'GET',headers:{Authorization:'Bearer '+session.token,...(body ? {'Content-Type':'application/json'} : {})},body:body ? JSON.stringify(body) : undefined,signal:controller.signal,credentials:'omit',redirect:'error',cache:'no-store',referrerPolicy:'no-referrer'});
    if (!response.ok) throw new HTTPFailure(response.status);
    if (!response.headers.get('Content-Type')?.startsWith('application/json') || !response.body) throw Error('Réponse du serveur invalide.');
    const reader = response.body.getReader(), chunks: Uint8Array[] = []; let size = 0;
    while (true) { const item = await reader.read(); if (item.done) break; size += item.value.length; if (size > 131072) { await reader.cancel(); throw Error('Réponse trop volumineuse.'); } chunks.push(item.value); }
    const bytes = new Uint8Array(size); let offset = 0; for (const chunk of chunks) { bytes.set(chunk,offset); offset += chunk.length; }
    return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes)) as unknown;
  } finally { clearTimeout(timer); if (active === controller) active = undefined; }
}
async function perform(work: (generation:number)=>Promise<void>) {
  const generation = ++epoch; clear(); el('error').hidden = true; el('status').textContent = 'Lecture ou décision en cours…';
  try { await work(generation); }
  catch (cause) { if (generation !== epoch) return; clear(); if (cause instanceof HTTPFailure && cause.code === 401) disconnect(); el('status').textContent = ''; el('error').hidden = false; el('error').textContent = cause instanceof HTTPFailure ? cause.message : cause instanceof Error && !['TypeError','AbortError','SyntaxError'].includes(cause.name) ? cause.message : 'Connexion interrompue ou réponse invalide. Actualisez pour vérifier la décision enregistrée.'; }
}
function sameCommand(a: Preview,b: Preview) { return (['id','runId','ledgerId','digest','commandFingerprint','tool','target','argumentsJSON','requestedAt','expiresAt'] as const).every(k=>a[k]===b[k]) && JSON.stringify(a.scope)===JSON.stringify(b.scope); }
function render(p: Preview) {
  current = p; el('connection').hidden = true; el('workspace').hidden = false; el('logout').hidden = false;
  const detail = el('detail'), title = node('h2','Commande à examiner'); title.tabIndex = -1; detail.replaceChildren(title,node('p',labels[p.decision]),node('h3','Outil'),node('p',p.tool),node('h3','Cible'),node('p',p.target),node('h3','Arguments exacts'),node('pre',p.argumentsJSON),node('h3','Portée'),node('p',p.scope.length ? p.scope.join('\n') : 'Aucune portée déclarée'),node('p','Empreinte de commande : '+p.commandFingerprint),node('p','Liaison de décision : '+p.digest),node('p',`Run : ${p.runId} · registre : ${p.ledgerId} · version ${p.version}`),node('p',`Demandée ${p.requestedAt} · expire ${p.expiresAt}`));
  if (p.decidedAt) detail.append(node('p','Décision enregistrée : '+p.decidedAt));
  const actions = document.createElement('div'); actions.className = 'actions'; detail.append(actions);
  const localExpired = () => Date.now() >= Date.parse(p.expiresAt);
  function expire() { if (current !== p) return; actions.replaceChildren(node('p','Échéance atteinte selon cette horloge. Actualisez pour vérifier l’état serveur.')); dialog.close(); }
  if (p.decision === 'pending') {
    if (localExpired()) expire(); else {
      for (const [value,label] of [['denied','Refuser'],['withdrawn','Retirer'],['approved','Autoriser']] as const) {
        const button = node('button',label); button.addEventListener('click',()=>{ if (current !== p || localExpired()) { expire(); return; } choice = value; el('confirm-text').textContent = `${label} « ${p.tool} » sur « ${p.target} » ? Vérifiez les arguments affichés. Liaison ${p.digest}.`; dialog.showModal(); el('cancel').focus(); }); actions.append(button);
      }
      expiryTimer = window.setTimeout(expire,Math.min(2147483647,Date.parse(p.expiresAt)-Date.now()));
    }
  }
  el('status').textContent = 'Demande chargée. '+labels[p.decision]+'.'; title.focus();
}
async function load(generation: number) { const p=decode(await request()); if (generation !== epoch) return; if (p.id.toLowerCase() !== session?.id) throw Error('Réponse hors de la demande sélectionnée.'); render(p); }
el('login').addEventListener('submit',event=>{event.preventDefault(); void perform(async generation=>{
  const origin=new URL(el<HTMLInputElement>('origin').value),token=el<HTMLInputElement>('token').value,id=el<HTMLInputElement>('approval').value.trim().toLowerCase();
  if (origin.protocol!=='http:' || !['localhost','127.0.0.1'].includes(origin.hostname) || origin.username || origin.password || origin.pathname!=='/' || origin.search || origin.hash || !/^[a-f0-9]{64}$/.test(token) || !uuid(id)) throw Error('Adresse HTTP locale, jeton hexadécimal et UUID de demande requis.');
  session={origin:origin.origin,token,id}; el<HTMLInputElement>('token').value=''; el('logout').hidden=false; await load(generation);
});});
el('reload').addEventListener('click',()=>void perform(load)); el('logout').addEventListener('click',disconnect); el('cancel').addEventListener('click',()=>dialog.close());
el('commit').addEventListener('click',()=>{
  const p=current,chosen=choice; if (!p || p.decision!=='pending') return;
  if (Date.now()>=Date.parse(p.expiresAt)) { clear(); el('error').textContent='Échéance atteinte. Actualisez avant toute décision.'; el('error').hidden=false; return; }
  void perform(async generation=>{const result=decode(await request({schemaVersion:'1',decision:chosen,digest:p.digest})); if (generation!==epoch) return;
    if (!sameCommand(p,result) || result.decision!==chosen || result.version!==p.version+1 || !result.decidedAt) throw Error('Décision non confirmée pour cette commande exacte. Actualisez.');
    render(result); el('status').textContent='Décision enregistrée : '+labels[result.decision]+'.';
  });
});
window.addEventListener('pagehide',disconnect);
