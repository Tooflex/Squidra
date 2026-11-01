export {};
type Receipt = {schemaVersion:'1';deployment:'synthetic'|'cloud';basis:'inferred';mediaRetained:false;frameId:string;cameraId:string;locationId:string;coordinateFrameId:string;modelId:string;modelVersion:string;imageSHA256:string;observedAt:string;knownAt:string;validityMilliseconds:number;observationEventId:string;entities:{id:string;localId:string;sourceEventId:string}[]};
const el=<T extends HTMLElement>(id:string)=>document.getElementById(id) as T;
const node=(tag:string,value:string)=>{const n=document.createElement(tag);n.textContent=value;return n;};
const uuid=(v:unknown):v is string=>typeof v==='string' && /^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(v);
const text=(v:unknown,max:number):v is string=>typeof v==='string' && v.length>0 && new TextEncoder().encode(v).length<=max;
const date=(v:unknown):v is string=>typeof v==='string' && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?Z$/.test(v) && Number.isFinite(Date.parse(v));
const object=(v:unknown):Record<string,unknown>=>{if(!v || typeof v!=='object' || Array.isArray(v)) throw Error('Réponse invalide.');return v as Record<string,unknown>;};
type ImportProfile={deployment:'synthetic'|'cloud';maximumImageBytes:number};
let importProfile:ImportProfile|undefined;
function decode(v:unknown,hash:string):Receipt {
 const p=object(v);
 if(p.schemaVersion!=='1' || p.deployment!==importProfile?.deployment || (p.deployment==='cloud' && (p.modelId!=='meta.sam'||p.modelVersion!=='alias:sam-3.1')) || p.basis!=='inferred' || p.mediaRetained!==false || !['frameId','cameraId','locationId','coordinateFrameId','observationEventId'].every(k=>uuid(p[k])) || !text(p.modelId,256) || !text(p.modelVersion,256) || p.imageSHA256!==hash || !date(p.observedAt) || !date(p.knownAt) || p.validityMilliseconds!==1000 || !Array.isArray(p.entities) || p.entities.length<1 || p.entities.length>16) throw Error('Reçu invalide ou sans liaison à cette image.');
 const ids=new Set<string>(),sources=new Set<string>(),locals=new Set<string>();
 for(const raw of p.entities) { const e=object(raw);if(!uuid(e.id)||!uuid(e.sourceEventId)||!text(e.localId,256)||ids.has(e.id.toLowerCase())||sources.has(e.sourceEventId.toLowerCase())||locals.has(e.localId)) throw Error('Entités du reçu invalides.');ids.add(e.id.toLowerCase());sources.add(e.sourceEventId.toLowerCase());locals.add(e.localId); }
 return p as Receipt;
}
let session:{origin:string;token:string}|undefined,epoch=0,active:AbortController|undefined,busy=false,attempted=false;
el('local-help').textContent='HTTP sur localhost ou 127.0.0.1 uniquement. Origine UI : '+location.origin;
function resetFile(){el<HTMLInputElement>('image').value='';el<HTMLInputElement>('consent').checked=false;el<HTMLInputElement>('cloud-consent').checked=false;}
function disconnect(){epoch++;active?.abort();session=undefined;importProfile=undefined;busy=false;attempted=false;resetFile();el<HTMLInputElement>('token').value='';el('receipt').replaceChildren();el('capability').textContent='';el('workspace').hidden=true;el('connection').hidden=false;el('logout').hidden=true;el('error').hidden=true;el('status').textContent='Session fermée.';el('origin').focus();}
class HTTPFailure extends Error {constructor(readonly code:number){super(({401:'Session refusée. Vérifiez le jeton.',403:'Traitement refusé.',404:'Import non configuré sur ce serveur.',413:'Image trop volumineuse.',503:'Service indisponible ou image non prise en charge.'} as Record<number,string>)[code]??`Erreur du serveur (${code}).`);}}
async function request(path:string,body?:object):Promise<unknown>{
 if(!session)throw Error('Connectez-vous au serveur.');const controller=new AbortController();active=controller;const timer=setTimeout(()=>controller.abort(),35000);
 try{const response=await fetch(session.origin+path,{method:body?'POST':'GET',headers:{Authorization:'Bearer '+session.token,...(body?{'Content-Type':'application/json'}:{})},body:body?JSON.stringify(body):undefined,credentials:'omit',redirect:'error',cache:'no-store',referrerPolicy:'no-referrer',signal:controller.signal});
 if(!response.ok)throw new HTTPFailure(response.status);if((body && response.status!==201)||!response.headers.get('Content-Type')?.startsWith('application/json')||!response.body)throw Error('Réponse invalide.');
 const reader=response.body.getReader(),chunks:Uint8Array[]=[];let size=0;while(true){const item=await reader.read();if(item.done)break;size+=item.value.length;if(size>65536){await reader.cancel();throw Error('Réponse trop volumineuse.');}chunks.push(item.value);}const bytes=new Uint8Array(size);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes)) as unknown;
 }finally{clearTimeout(timer);if(active===controller)active=undefined;}
}
function failure(cause:unknown,submitted:boolean){if(cause instanceof HTTPFailure && cause.code===401)disconnect();el('status').textContent='';el('error').hidden=false;el('error').textContent=(cause instanceof HTTPFailure?cause.message:cause instanceof Error&&!['AbortError','TypeError','SyntaxError'].includes(cause.name)?cause.message:'Connexion interrompue ou réponse invalide.')+(submitted?' Aucun reçu confirmé. Ne renvoyez pas automatiquement l’image : une observation peut avoir été enregistrée. Vérifiez le journal ou la chronologie.':'');}
el('login').addEventListener('submit',event=>{event.preventDefault();if(busy)return;busy=true;const generation=++epoch;el('error').hidden=true;void(async()=>{try{
 const origin=new URL(el<HTMLInputElement>('origin').value),token=el<HTMLInputElement>('token').value;
 if(origin.protocol!=='http:'||!['127.0.0.1','localhost'].includes(origin.hostname)||origin.username||origin.password||origin.pathname!=='/'||origin.search||origin.hash||!/^[a-f0-9]{64}$/.test(token))throw Error('Adresse HTTP locale et jeton hexadécimal requis.');
 session={origin:origin.origin,token};el<HTMLInputElement>('token').value='';el('logout').hidden=false;
 const p=object(await request('/api/v1/run-capabilities'));if(generation!==epoch)return;
 if(p.schemaVersion!=='1'||typeof p.textRuns!=='boolean'||(!p.textRuns&&p.limitation!=='no_configured_read_host'))throw Error('Capacités du serveur invalides.');
 el('capability').textContent=p.textRuns?'Le serveur annonce un moteur de questions. La page « Question historique » permet de soumettre une question pour une entité autorisée.':'Questions en langage libre indisponibles : aucun moteur de lecture configuré sur ce serveur.';
 const c=object(await request('/api/v1/frame-import-capabilities'));if(generation!==epoch)return;
 if(c.schemaVersion!=='1'||!['synthetic','cloud'].includes(c.deployment as string)||c.requiresCloudTransferConsent!==(c.deployment==='cloud')||c.maximumImageBytes!==(c.deployment==='cloud'?65536:524288))throw Error('Profil d’import invalide.');
 importProfile={deployment:c.deployment as ImportProfile['deployment'],maximumImageBytes:c.maximumImageBytes as number};
 el('image-label').textContent=importProfile.deployment==='cloud'?'Image PNG (64 Kio maximum, dimensions maximales 1024 × 1024)':'Image PNG de la fixture (512 Kio maximum)';
 el('profile').textContent=importProfile.deployment==='cloud'?'SAM 3.1 via Meta : l’image sera transférée au fournisseur. Squidra ne conserve pas les octets ; la conservation chez Meta dépend des conditions du compte. Les positions sont inférées à partir de la scène configurée, sans calibration spatiale.':'Fixture synthétique locale : seule l’image configurée est reconnue. Ce mode ne qualifie pas SAM.';
 el('cloud-consent-label').hidden=importProfile.deployment!=='cloud';el<HTMLInputElement>('cloud-consent').required=importProfile.deployment==='cloud';
 el('connection').hidden=true;el('workspace').hidden=false;prepare();el('status').textContent='Session ouverte.';el('image').focus();
 }catch(cause){if(generation===epoch)failure(cause,false);}finally{if(generation===epoch)busy=false;}})();});
function prepare(){el('status').textContent='Sélectionnez une image et confirmez les consentements requis.';attempted=false;resetFile();el('receipt').replaceChildren();el('import-form').hidden=false;el('new-import').hidden=true;el<HTMLButtonElement>('submit-import').disabled=false;el('error').hidden=true;el('image').focus();}
el('new-import').addEventListener('click',()=>{if(!busy)prepare();});
el('import-form').addEventListener('submit',event=>{event.preventDefault();if(busy||attempted||!session||!importProfile)return;busy=true;const generation=++epoch;el<HTMLButtonElement>('submit-import').disabled=true;el('error').hidden=true;let submitted=false;
 void(async()=>{try{
 const file=el<HTMLInputElement>('image').files?.[0];if(!file||file.size<8||file.size>importProfile!.maximumImageBytes||!el<HTMLInputElement>('consent').checked)throw Error(`PNG de ${importProfile!.maximumImageBytes/1024} Kio maximum et consentement local requis.`);
 if(importProfile!.deployment==='cloud'&&!el<HTMLInputElement>('cloud-consent').checked)throw Error('Consentement au transfert à Meta requis.');
 const bytes=new Uint8Array(await file.arrayBuffer());if(generation!==epoch)return;
 if(![137,80,78,71,13,10,26,10].every((v,i)=>bytes[i]===v))throw Error('Signature PNG invalide.');
 const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),v=>v.toString(16).padStart(2,'0')).join('');if(generation!==epoch)return;
 let binary='';for(const byte of bytes)binary+=String.fromCharCode(byte);
 attempted=true;submitted=true;el('status').textContent='Import en cours…';resetFile();
 const result=await request('/api/v1/frames/import',{schemaVersion:'1',imageBase64:btoa(binary),permitsLocalProcessing:true,...(importProfile!.deployment==='cloud'?{permitsCloudTransfer:true}:{})});if(generation!==epoch)return;const p=decode(result,hash);
 const receipt=el('receipt'),title=node('h2',p.deployment==='cloud'?'Observation SAM enregistrée':'Observation synthétique enregistrée');title.tabIndex=-1;receipt.replaceChildren(title,node('p','Position inférée · image non conservée par Squidra · validité 1 seconde. Ce reçu ne constitue pas une réponse à une question historique.'));
 for(const [label,value] of [['Image SHA-256',p.imageSHA256],['Modèle',p.modelId+' / '+p.modelVersion],['Image source',p.frameId],['Caméra',p.cameraId],['Lieu configuré',p.locationId],['Repère spatial',p.coordinateFrameId],['Événement d’observation',p.observationEventId],['Observé à (instant valide)',p.observedAt],['Connu à (transaction)',p.knownAt]]){receipt.append(node('h3',label!),node('pre',value!));}
 receipt.append(node('p','Conservez les dates complètes ci-dessus, y compris les microsecondes. Une troncature peut sélectionner un autre état temporel.'));
 for(const e of p.entities)receipt.append(node('h3','Entité '+e.localId),node('pre',e.id),node('p','Événement source de position : '+e.sourceEventId));
 el('status').textContent='Reçu vérifié pour cette image.';title.focus();
 }catch(cause){if(generation===epoch)failure(cause,submitted);}finally{if(generation===epoch){busy=false;if(attempted){el('import-form').hidden=true;el('new-import').hidden=false;}else el<HTMLButtonElement>('submit-import').disabled=false;}}})();});
el('logout').addEventListener('click',disconnect);window.addEventListener('pagehide',disconnect);
