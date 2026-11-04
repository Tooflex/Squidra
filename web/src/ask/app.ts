import {acceptance,consume,freshStream,object,text,uuid,type Acceptance,type Answer,type Stream} from '../questions/protocol.js';
type Profile={deployment:'synthetic'|'cloud';maximumImageBytes:number};
type Receipt={deployment:string;observedAt:string;knownAt:string;entities:{id:string;localId:string}[]};
type Context={entityId:string;label:string;observedAt?:string;knownAt?:string};
type Photo={bytes:Uint8Array;hash:string;url:string};
const el=<T extends HTMLElement>(id:string)=>document.getElementById(id) as T;
const mk=(tag:string,value='',cls='')=>{const n=document.createElement(tag);if(tag==='button')n.setAttribute('type','button');n.textContent=value;if(cls)n.className=cls;return n;};
const dateOK=(v:unknown):v is string=>typeof v==='string'&&/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?Z$/.test(v)&&Number.isFinite(Date.parse(v));
let session:{origin:string;token:string}|undefined,profile:Profile|undefined,runsEnabled=false;
let epoch=0,busy=false,active:AbortController|undefined,context:Context|undefined,photo:Photo|undefined,stream:MediaStream|undefined;
let run:Acceptance|undefined,runStream:Stream=freshStream(),runEntity='',lastWaiting:HTMLElement|undefined;
el('local-help').textContent='HTTP sur localhost ou 127.0.0.1 uniquement. Origine UI : '+location.origin;

class HTTPFailure extends Error{constructor(readonly code:number){super(({401:'Code d’accès refusé. Vérifiez-le.',403:'Cet objet ou cette action n’est pas autorisé.',404:'Cette fonction n’est pas configurée sur le serveur.',409:'Conflit d’état. Réessayez plus tard.',410:'La réponse a expiré et ne peut plus être reconstruite.',413:'La photo ou la question est trop volumineuse.',503:'Le service est indisponible pour le moment.',504:'Le serveur a mis trop de temps à répondre.'} as Record<number,string>)[code]??`Erreur du serveur (${code}).`);}}
async function request(path:string,opts:{body?:object;sse?:boolean;cursor?:string;created?:number}={}):Promise<string>{
 if(!session)throw Error('Connectez-vous d’abord.');
 const controller=new AbortController();active=controller;const timer=setTimeout(()=>controller.abort(),opts.sse?27000:35000);
 try{
  const r=await fetch(session.origin+path,{method:opts.body?'POST':'GET',headers:{Authorization:'Bearer '+session.token,...(opts.body?{'Content-Type':'application/json'}:{}),...(opts.cursor?{'Last-Event-ID':opts.cursor}:{})},body:opts.body?JSON.stringify(opts.body):undefined,credentials:'omit',redirect:'error',cache:'no-store',referrerPolicy:'no-referrer',signal:controller.signal});
  if(!r.ok)throw new HTTPFailure(r.status);
  if((opts.body&&r.status!==opts.created)||!r.headers.get('Content-Type')?.startsWith(opts.sse?'text/event-stream':'application/json')||!r.body)throw Error('Réponse invalide du serveur.');
  const reader=r.body.getReader(),chunks:Uint8Array[]=[];let size=0;const limit=opts.sse?1100000:65536;
  for(;;){const it=await reader.read();if(it.done)break;size+=it.value.length;if(size>limit){await reader.cancel();throw Error('Réponse trop volumineuse.');}chunks.push(it.value);}
  const all=new Uint8Array(size);let off=0;for(const c of chunks){all.set(c,off);off+=c.length;}
  return new TextDecoder('utf-8',{fatal:true}).decode(all);
 }finally{clearTimeout(timer);if(active===controller)active=undefined;}
}
function showError(cause:unknown,extra=''){
 if(cause instanceof HTTPFailure&&cause.code===401){disconnect();}
 el('status').textContent='';const e=el('error');e.hidden=false;
 e.textContent=(cause instanceof HTTPFailure?cause.message:cause instanceof Error&&!['AbortError','TypeError','SyntaxError'].includes(cause.name)?cause.message:'Connexion interrompue ou réponse invalide.')+extra;
}
function bubble(role:'user'|'bot',...children:(Node|string)[]){const b=mk('div','',role==='user'?'bubble me':'bubble bot');b.append(...children);el('log').append(b);b.scrollIntoView({block:'end'});return b;}
function setBusy(v:boolean){busy=v;for(const id of ['send','camera','message','shoot'])el<HTMLButtonElement>(id).disabled=v;}
function setContext(c?:Context){context=c;el('context').hidden=!c;if(c)el('context-text').textContent='Sujet : '+c.label+(c.observedAt?' · photo du '+new Date(c.observedAt).toLocaleString('fr-FR'):'');}
function stopCamera(){stream?.getTracks().forEach(t=>t.stop());stream=undefined;el<HTMLVideoElement>('video').srcObject=null;el('camera-panel').hidden=true;}
function dropPhoto(){if(photo)URL.revokeObjectURL(photo.url);photo=undefined;el('attachment').hidden=true;el<HTMLInputElement>('consent').checked=false;}
function disconnect(){
 epoch++;active?.abort();stopCamera();dropPhoto();session=undefined;profile=undefined;runsEnabled=false;busy=false;run=undefined;runStream=freshStream();setContext(undefined);
 el('log').replaceChildren();el<HTMLTextAreaElement>('message').value='';el<HTMLInputElement>('token').value='';el<HTMLInputElement>('entity').value='';setBusy(false);
 el('chat').hidden=true;el('connection').hidden=false;el('logout').hidden=true;el('error').hidden=true;el('status').textContent='Session fermée.';el('token').focus();
}

// Connexion
el('toggle-token').addEventListener('click',()=>{const t=el<HTMLInputElement>('token'),shown=t.type==='text';t.type=shown?'password':'text';el('toggle-token').textContent=shown?'Afficher':'Masquer';el('toggle-token').setAttribute('aria-pressed',String(!shown));});
el('login').addEventListener('submit',ev=>{ev.preventDefault();if(busy)return;setBusy(true);const g=++epoch;el('error').hidden=true;
 void(async()=>{try{
  const origin=new URL(el<HTMLInputElement>('origin').value),token=el<HTMLInputElement>('token').value,manual=el<HTMLInputElement>('entity').value.trim().toLowerCase();
  if(origin.protocol!=='http:'||!['localhost','127.0.0.1'].includes(origin.hostname)||origin.username||origin.password||origin.pathname!=='/'||origin.search||origin.hash||!/^[a-f0-9]{64}$/.test(token))throw Error('Le code d’accès doit contenir 64 caractères (chiffres 0-9 et lettres a-f).');
  if(manual&&!uuid(manual))throw Error('Le numéro d’objet n’a pas le bon format.');
  session={origin:origin.origin,token};el<HTMLInputElement>('token').value='';el('logout').hidden=false;
  const caps=object(JSON.parse(await request('/api/v1/run-capabilities')));if(g!==epoch)return;
  if(caps.schemaVersion!=='1'||typeof caps.textRuns!=='boolean')throw Error('Le serveur a répondu de façon inattendue.');
  runsEnabled=caps.textRuns;profile=undefined;
  try{const c=object(JSON.parse(await request('/api/v1/frame-import-capabilities')));if(g!==epoch)return;
   if(c.schemaVersion==='1'&&['synthetic','cloud'].includes(c.deployment as string)&&c.requiresCloudTransferConsent===(c.deployment==='cloud')&&typeof c.maximumImageBytes==='number'&&c.maximumImageBytes>0&&c.maximumImageBytes<=524288)profile={deployment:c.deployment as 'synthetic'|'cloud',maximumImageBytes:c.maximumImageBytes};
  }catch(e){if(e instanceof HTTPFailure&&e.code===401)throw e;}
  if(g!==epoch)return;
  el('log').replaceChildren();setContext(manual?{entityId:manual,label:'objet n° '+manual.slice(0,8)+'…'}:undefined);
  el('connection').hidden=true;el('chat').hidden=false;el('status').textContent='Connecté.';
  bubble('bot',mk('p',runsEnabled?'Bonjour ! Appuyez sur 📷 pour montrer un objet, puis posez votre question. Je réponds d’après ce que j’ai observé, avec mes preuves.':'Connecté, mais le serveur ne peut pas répondre aux questions pour le moment (aucun moteur configuré).'));
  el<HTMLButtonElement>('camera').hidden=!profile;if(!profile)bubble('bot',mk('p','La caméra n’est pas disponible sur ce serveur : indiquez un numéro d’objet dans les réglages avancés.'));
  el('message').focus();
 }catch(c){if(g===epoch)showError(c);}finally{if(g===epoch)setBusy(false);}})();});

// Caméra
el('camera').addEventListener('click',()=>{void(async()=>{
 if(busy||!profile)return;el('error').hidden=true;
 if(!navigator.mediaDevices?.getUserMedia){showError(new Error('Ce navigateur ne permet pas d’utiliser la caméra.'));return;}
 try{stopCamera();const g=epoch;const s=await navigator.mediaDevices.getUserMedia({video:{facingMode:'environment'},audio:false});
  if(g!==epoch||!session){s.getTracks().forEach(t=>t.stop());return;}
  stream=s;const v=el<HTMLVideoElement>('video');v.srcObject=s;await v.play();el('camera-panel').hidden=false;el('shoot').focus();
 }catch{showError(new Error('Caméra inaccessible. Autorisez-la dans votre navigateur (icône de caméra près de la barre d’adresse).'));}
 })();});
el('cancel-camera').addEventListener('click',()=>{stopCamera();el('camera').focus();});
async function encode(v:HTMLVideoElement,max:number):Promise<Blob>{
 const w=v.videoWidth,h=v.videoHeight;if(!w||!h)throw Error('La caméra n’est pas encore prête.');
 const canvas=document.createElement('canvas'),ctx=canvas.getContext('2d',{willReadFrequently:true});if(!ctx)throw Error('Capture impossible sur ce navigateur.');
 for(const [side,mask] of [[1024,0xFF],[640,0xFF],[480,0xF0],[320,0xF0],[240,0xE0],[160,0xE0]] as [number,number][]){
  const k=Math.min(1,side/Math.max(w,h));canvas.width=Math.max(1,Math.round(w*k));canvas.height=Math.max(1,Math.round(h*k));ctx.drawImage(v,0,0,canvas.width,canvas.height);
  if(mask!==0xFF){const d=ctx.getImageData(0,0,canvas.width,canvas.height);for(let i=0;i<d.data.length;i+=4){d.data[i]=d.data[i]!&mask;d.data[i+1]=d.data[i+1]!&mask;d.data[i+2]=d.data[i+2]!&mask;}ctx.putImageData(d,0,0);}
  const blob=await new Promise<Blob|null>(r=>canvas.toBlob(r,'image/png'));if(blob&&blob.size>=8&&blob.size<=max)return blob;
 }
 throw Error('Impossible de réduire la photo à la taille autorisée. Rapprochez-vous de l’objet ou changez d’éclairage.');
}
el('shoot').addEventListener('click',()=>{void(async()=>{
 if(!profile)return;try{
  const blob=await encode(el<HTMLVideoElement>('video'),profile.maximumImageBytes),bytes=new Uint8Array(await blob.arrayBuffer());
  const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),b=>b.toString(16).padStart(2,'0')).join('');
  dropPhoto();photo={bytes,hash,url:URL.createObjectURL(blob)};stopCamera();
  el<HTMLImageElement>('preview').src=photo.url;
  el('consent-text').textContent=profile.deployment==='cloud'?'J’autorise l’envoi de cette photo à Meta (modèle SAM 3.1) pour repérer les objets. Squidra ne la conserve pas.':'J’autorise le traitement de cette photo sur ce serveur. Squidra ne la conserve pas.';
  el('attachment').hidden=false;el('message').focus();
 }catch(c){showError(c);}
 })();});
el('remove-photo').addEventListener('click',()=>{dropPhoto();el('message').focus();});

// Envoi
function decodeReceipt(v:unknown,hash:string):Receipt{
 const p=object(v);
 if(p.schemaVersion!=='1'||p.deployment!==profile?.deployment||(p.deployment==='cloud'&&(p.modelId!=='meta.sam'||p.modelVersion!=='alias:sam-3.1'))||p.basis!=='inferred'||p.mediaRetained!==false||p.imageSHA256!==hash||!dateOK(p.observedAt)||!dateOK(p.knownAt)||!Array.isArray(p.entities)||p.entities.length<1||p.entities.length>16)throw Error('Le reçu de la photo est invalide ou ne correspond pas à cette image.');
 const ids=new Set<string>();for(const raw of p.entities){const e=object(raw);if(!uuid(e.id)||!text(e.localId,256)||ids.has(e.id.toLowerCase()))throw Error('Objets du reçu invalides.');ids.add(e.id.toLowerCase());}
 return p as unknown as Receipt;
}
const label=(e:{localId:string})=>e.localId.replace(/[_-]+/g,' ');
el('composer').addEventListener('submit',ev=>{ev.preventDefault();void send();});
el('message').addEventListener('keydown',ev=>{const k=ev as KeyboardEvent;if(k.key==='Enter'&&!k.shiftKey&&!k.isComposing){k.preventDefault();void send();}});
async function send(){
 if(busy||!session)return;const g=epoch,box=el<HTMLTextAreaElement>('message'),question=box.value.trim();el('error').hidden=true;
 if(!photo&&!question)return;
 if(question&&!runsEnabled){showError(new Error('Le serveur ne peut pas répondre aux questions pour le moment.'));return;}
 if(photo&&!el<HTMLInputElement>('consent').checked){showError(new Error('Cochez la case d’autorisation pour envoyer la photo.'));el('consent').focus();return;}
 if(!photo&&!context){showError(new Error('Pour répondre, j’ai besoin d’un objet : prenez-le en photo avec 📷.'));return;}
 setBusy(true);
 const mine:(Node|string)[]=[];if(photo){const img=document.createElement('img');img.src=photo.url;img.alt='Photo envoyée';mine.push(img);}if(question)mine.push(mk('p',question));bubble('user',...mine);box.value='';
 try{
  let ctx=context;
  if(photo){
   const sent=photo;const wait=bubble('bot',mk('p','Je regarde la photo…'));el('status').textContent='Analyse de la photo en cours…';
   let receipt:Receipt;
   try{
    const raw=await request('/api/v1/frames/import',{body:{schemaVersion:'1',imageBase64:btoa(Array.from(sent.bytes,b=>String.fromCharCode(b)).join('')),permitsLocalProcessing:true,...(profile!.deployment==='cloud'?{permitsCloudTransfer:true}:{})},created:201});
    if(g!==epoch)return;receipt=decodeReceipt(JSON.parse(raw),sent.hash);
   }catch(c){wait.remove();showError(c,c instanceof HTTPFailure&&c.code===401?'':' La photo n’est pas renvoyée automatiquement : une observation a peut-être été enregistrée.');return;}
   dropPhoto();wait.replaceChildren(mk('p',receipt.entities.length===1?'J’ai repéré un objet : '+label(receipt.entities[0]!)+'.':'J’ai repéré '+receipt.entities.length+' objets.'));
   const base={observedAt:receipt.observedAt,knownAt:receipt.knownAt};
   if(receipt.entities.length===1){const e=receipt.entities[0]!;ctx={entityId:e.id.toLowerCase(),label:label(e),...base};setContext(ctx);}
   else{
    ctx=undefined;setContext(undefined);
    if(!question){wait.append(mk('p','Précisez ensuite l’objet voulu.'));}
    const row=mk('div','','choices');
    for(const e of receipt.entities){const b=mk('button',label(e),'secondary');b.addEventListener('click',()=>{if(busy)return;row.remove();const c={entityId:e.id.toLowerCase(),label:label(e),...base};setContext(c);if(question){setBusy(true);void ask(question,c,epoch).finally(()=>{if(g===epoch)setBusy(false);});}else bubble('bot',mk('p','Objet choisi : '+c.label+'. Posez votre question.'));});row.append(b);}
    if(question)wait.append(mk('p','De quel objet parlez-vous ?'));wait.append(row);return;
   }
   if(!question){wait.append(mk('p','Posez maintenant votre question.'));return;}
  }
  if(question&&ctx)await ask(question,ctx,g);
 }catch(c){if(g===epoch)showError(c);}finally{if(g===epoch){setBusy(false);el('message').focus();}}
}
async function ask(question:string,c:Context,g:number){
 const full=c.observedAt&&c.knownAt?`${question}\n\n(Photo observée le ${c.observedAt}, enregistrée le ${c.knownAt}.)`:question;
 if(!text(full,4096))throw Error('La question est trop longue (4 096 octets maximum).');
 runEntity=c.entityId;run=undefined;runStream=freshStream();const wait=bubble('bot',mk('p','Je réfléchis…'));el('status').textContent='Question envoyée…';
 let accepted:Acceptance;
 try{accepted=acceptance(JSON.parse(await request('/api/v1/runs',{body:{schemaVersion:'1',question:full,entityId:c.entityId,intent:'historical'},created:202})));}
 catch(e){wait.remove();if(g===epoch)showError(e,e instanceof HTTPFailure&&[401,403,413].includes(e.code)?'':' Un envoi a peut-être été créé côté serveur ; la question n’est pas renvoyée automatiquement.');return;}
 if(g!==epoch)return;run=accepted;wait.remove();await pump(g);
}
async function pump(g:number){
 if(!run)return;lastWaiting?.remove();lastWaiting=undefined;const wait=bubble('bot',mk('p','Je cherche dans mes observations…'));
 try{
  for(let i=0;i<4&&!runStream.terminal;i++){const body=await request(run.events,{sse:true,cursor:runStream.cursor});if(g!==epoch)return;runStream=consume(runStream,body,run,runEntity);}
  if(g!==epoch)return;wait.remove();
  if(runStream.terminal==='success'&&runStream.answer){renderAnswer(runStream.answer);el('status').textContent='Réponse reçue.';}
  else if(runStream.terminal){bubble('bot',mk('p',runStream.terminal==='cancelled'?'La recherche a été annulée. Pas de réponse.':'La recherche a échoué ('+runStream.failure+'). Pas de réponse.'));el('status').textContent='';}
  else{const b=bubble('bot',mk('p','La réponse se fait attendre.'));const more=mk('button','Continuer d’attendre','secondary');more.addEventListener('click',()=>{if(busy)return;setBusy(true);void pump(epoch).finally(()=>{if(g===epoch)setBusy(false);});});b.append(more);lastWaiting=b;}
 }catch(c){wait.remove();if(g===epoch){showError(c);if(c instanceof HTTPFailure&&[404,410].includes(c.code)){run=undefined;runStream=freshStream();}else if(run&&!runStream.terminal){const b=bubble('bot',mk('p','La connexion a été interrompue.'));const retry=mk('button','Reprendre la réponse','secondary');retry.addEventListener('click',()=>{if(busy)return;el('error').hidden=true;setBusy(true);void pump(epoch).finally(()=>{if(g===epoch)setBusy(false);});});b.append(retry);lastWaiting=b;}}}
}
function renderAnswer(a:Answer){
 const badge=({grounded:'Réponse avec preuves',partial:'Réponse partielle',unknown:'Je ne sais pas'})[a.status];
 const b=bubble('bot',mk('p',badge,'badge'),mk('p',a.text,'answer-text'));
 if(a.uncertainty.length)b.append(mk('p','Limites : '+a.uncertainty.join(' · '),'hint'));
 if(a.evidence.length){
  const d=document.createElement('details');d.append(mk('summary',`Voir les preuves (${a.evidence.length})`));
  for(const e of a.evidence){const p=document.createElement('div');p.className='proof';p.append(mk('strong',(e.basis==='inferred'?'Déduit':'Observé')+' · confiance '+Math.round(e.confidence*100)+' %'),mk('p','Source : '+e.source),mk('p','Observé à : '+e.observedAt+' · Enregistré à : '+e.recordedAt),mk('p','Fraîcheur : '+({fresh:'récente',stale:'ancienne',clock_skew:'horloge incohérente'})[e.freshness]));d.append(p);}
  b.append(d);
 }else b.append(mk('p','Aucune preuve fournie : cela ne prouve pas que l’objet est absent.','hint'));
}
el('logout').addEventListener('click',disconnect);window.addEventListener('pagehide',disconnect);
