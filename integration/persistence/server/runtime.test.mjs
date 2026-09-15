import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import * as serverSdk from '../../../packages/server/index.mts';
import {createBackend,MutationRejected,EngineError,RECORD} from '../../../packages/server/index.mts';
import {PrismaPersistence,prismaTransactions,prisma} from '../../../packages/persistence-prisma/index.mts';
const require=createRequire(import.meta.url);
const {PrismaClient}=require('../../bindings/node/generated/client');
const native=require('../../../bindings/node/ahead-node.node');
const db=new PrismaClient();
const schema={enums:[],models:[{name:'Task',identity:['id'],fields:[{name:'id',type:{kind:'scalar',name:'string'},nullable:false},{name:'title',type:{kind:'scalar',name:'string'},nullable:false}]}]};
const config={schema,mutations:[{name:'edit',version:1,slots:[{name:'task',model:'Task',operation:'update',cardinality:'single',allowedPatchFields:['title']}]}]};
const authenticate=async req=>req.headers.authorization==='Bearer alice'?'alice':null;
let called=0,prepared=0,lastInput;const seenChannels=[];
const backend=createBackend({config,database:prisma(db),authenticate,handlers:{
 async edit({input,tx,notify}){
  called++;lastInput=input;const {identity,patch}=input.task;
  await tx.$executeRawUnsafe('INSERT INTO business_task(id,title) VALUES($1,$2) ON CONFLICT(id) DO UPDATE SET title=$2',identity.id,patch.title);
  if(patch.title==='empty-channel')notify({channel:'',records:[]});
  if(patch.title==='bad-records')notify({channel:'shared',records:'x'});
  if(patch.title==='bogus-record')notify({channel:'shared',records:[{bogus:true}]});
  notify({channel:'shared',records:[input.task]});
  if(patch.title==='refuse')throw new MutationRejected('task.refused');if(patch.title==='crash')throw new Error('business crash');
  if(patch.title==='two'||patch.title==='pick')notify({channel:'other',records:[input.task]});
  if(patch.title==='pick')return {channel:'other'};
  if(patch.title==='empty-checkpoint')return {channel:''};
  if(patch.title==='never-checkpoint')return {channel:'never'};
 }},
 loaders:{async task({ids,tx,channel}){seenChannels.push(channel);return Promise.all(ids.map(async identity=>{const rows=await tx.$queryRawUnsafe('SELECT title FROM business_task WHERE id=$1',identity.id);return rows[0]??null;}));}},
 loaderHooks:{task:{async prepareForViewer(){prepared++}}},
});
const mutation=(ordinal,title,id='a')=>({ordinal,name:'edit',operations:[{model:'Task',op:'update',identity:{id},values:{title}}]});
const push=(clientId,batchSequence,mutations)=>JSON.stringify({clientId,batchSequence,mutations});
const pull=(scope='shared',fromCursor=0)=>backend.pull('alice',JSON.stringify({clientId:'c',scope,fromCursor})).then(JSON.parse);
const count=async table=>Number((await db.$queryRawUnsafe(`SELECT count(*) AS count FROM ${table}`))[0].count);
before(async()=>{for(const sql of (await readFile(new URL('../../../packages/persistence-prisma/migration.sql',import.meta.url),'utf8')).split(';').map(x=>x.trim()).filter(Boolean))await db.$executeRawUnsafe(sql);await db.$executeRawUnsafe('CREATE TABLE business_task(id text PRIMARY KEY,title text NOT NULL)');});
after(()=>db.$disconnect());
test('native exports production runtime',()=>{assert.equal(typeof native.processPush,'function');assert.equal(typeof native.processPull,'function');assert.equal(typeof native.publish,'function');assert.equal(typeof native.validateConfig,'function');
 assert.equal(typeof native.negotiateLive,'function');assert.equal(typeof native.pullLive,'function');
 assert.equal(typeof native.liveEvent,'function');assert.equal(typeof native.liveClose,'function');
 assert.throws(()=>native.liveEvent(0,JSON.stringify({type:'closed'})),error=>JSON.parse(error.message).code==='live.invalid_event','an event on a handle that is not open is a host defect');
 native.liveClose(0);
});
test('backend validates config and complete registrations at startup',()=>{
 const base={...config,schema:structuredClone(schema)};
 assert.throws(()=>createBackend({config:{...base,mutations:[{name:'bad',version:0,slots:[]}]},native,database:prisma(db),authenticate,handlers:{},loaders:{task:async()=>[]}}),/invalid mutation descriptor/);
 assert.throws(()=>createBackend({config:base,native,database:prisma(db),authenticate,handlers:{},loaders:{task:async()=>[]}}),/Missing handler edit for edit v1/);
 assert.throws(()=>createBackend({config:base,native,database:prisma(db),authenticate,handlers:{edit:async()=>{}},loaders:{}}),/Missing loader task for Task v1/);
});
test('loader registration names every retained model version and a function means v1 only',()=>{
 const base={...config,schema:structuredClone(schema)};
 const contract=version=>({name:'Task',version,identity:['id'],fields:schema.models[0].fields,enums:[]});
 const register=(models,loaders,currentVersion=1)=>{const c={...base,schema:structuredClone(schema),models};c.schema.models[0].version=currentVersion;return createBackend({config:c,native,database:prisma(db),authenticate,handlers:{edit:async()=>{}},loaders});};
 const both=[contract(1),contract(2)];
 assert.throws(()=>register(both,{task:async()=>[]},2),/Loader task must register v1, v2 of Task; a function registers v1 only/);
 assert.throws(()=>register([contract(2)],{task:async()=>[]},2),/Loader task must register v2 of Task; a function registers v1 only/);
 assert.throws(()=>register(both,{task:{v1:async()=>[]}},2),/Missing loader task\.v2 for Task v2/);
 assert.throws(()=>register(both,{task:{v1:async()=>[],v2:async()=>[],v3:async()=>[]}},2),/Unknown loader task\.v3 for Task: retained versions are v1, v2/);
 assert.throws(()=>register(both,{task:{v1:async()=>[],v2:'later'}},2),/Loader task\.v2 for Task v2 must be a function/);
 assert.throws(()=>register(both,{task:null},2),/Missing loader task for Task v1, v2/);
 // The engine refuses a schema whose current version is not a retained contract.
 assert.throws(()=>register([contract(1)],{task:{v1:async()=>[]}},2),/not a retained contract/);
 register(both,{task:{v1:async()=>[],v2:async()=>[]}},2);
 register([contract(1)],{task:{v1:async()=>[]}});
 register([contract(1)],{task:async()=>[]});
 register([],{task:async()=>[]});
});
test('handler registration names every retained version and a function means v1 only',()=>{
 const base={...config,schema:structuredClone(schema)};
 const register=(mutations,handlers)=>createBackend({config:{...base,mutations},native,database:prisma(db),authenticate,handlers,loaders:{task:async()=>[]}});
 const both=[config.mutations[0],{...config.mutations[0],version:2}];
 assert.throws(()=>register(both,{edit:async()=>{}}),/Handler edit must register v1, v2 of edit; a function registers v1 only/);
 assert.throws(()=>register([{...config.mutations[0],version:2}],{edit:async()=>{}}),/Handler edit must register v2 of edit; a function registers v1 only/);
 assert.throws(()=>register(both,{edit:{v1:async()=>{}}}),/Missing handler edit\.v2 for edit v2/);
 assert.throws(()=>register(both,{edit:{v1:async()=>{},v2:async()=>{},v3:async()=>{}}}),/Unknown handler edit\.v3 for edit: retained versions are v1, v2/);
 assert.throws(()=>register(both,{edit:{v1:async()=>{},v2:'later'}}),/Handler edit\.v2 for edit v2 must be a function/);
 assert.throws(()=>register(both,{edit:null}),/Missing handler edit for edit v1, v2/);
 register(both,{edit:{v1:async()=>{},v2:async()=>{}}});
 register([config.mutations[0]],{edit:{v1:async()=>{}}});
 register([config.mutations[0]],{edit:async()=>{}});
});
test('Prisma persistence supports reusable bind without owning a transaction',async()=>{
 const reusable=new PrismaPersistence();let calls=0;
 const tx={$queryRawUnsafe:async()=>[{head:4}],$executeRawUnsafe:async()=>{calls++;return 1}};
 assert.equal(await reusable.bind(tx).call({op:'head',channel:'x'}),4);
 await reusable.bind(tx).call({op:'saveReceipt',clientId:'c',owner:'o',sequence:1,receipt:'r'});
 assert.equal(calls,1);
});
test('push commits business + compacted publication + exact durable receipt together',async()=>{
 const request=push('dedup',1,[mutation(1,'first')]);const receipt=await backend.push('alice',request);assert.deepEqual(JSON.parse(receipt),{requiredCheckpoints:[{scope:'shared',syncId:1}],requiredScope:'shared',requiredSyncId:1,rejections:[]});const calls=called;
 // Replay is keyed by (clientId, batchSequence): the same frozen bytes and a changed body both return the stored receipt without a handler call, a business write, a publication or a subscriber wake.
 let wakes=0;const unsubscribe=backend.onCommitted('shared',()=>{wakes++;});const rows=await count('ahead_invalidation');
 assert.equal(await backend.push('alice',request),receipt);assert.equal(called,calls);
 assert.equal(await backend.push('alice',push('dedup',1,[mutation(1,'changed')])),receipt);assert.equal(called,calls);
 await new Promise(resolve=>setImmediate(resolve));unsubscribe();assert.equal(wakes,0,'replayed receipts must not wake subscribers');
 assert.deepEqual(await db.$queryRawUnsafe("SELECT title FROM business_task WHERE id='a'"),[{title:'first'}]);assert.equal(await count('ahead_invalidation'),rows);
 await assert.rejects(()=>backend.push('bob',request),/owner_mismatch/);
 await assert.rejects(()=>backend.push('alice',push('dedup',3,[mutation(1,'gap')])),/gap/);
 const page=await pull();assert.deepEqual(page,{scope:'shared',fromCursor:0,toCursor:1,changes:[{syncId:1,model:'Task',identity:{id:'a'},stamp:1,state:{title:'first'}}]});assert.equal(prepared,1);
});
test('explicit rejection rolls back only mutation and its publication',async()=>{
 const result=JSON.parse(await backend.push('alice',push('refusal',1,[mutation(1,'good','b'),mutation(2,'refuse','c'),mutation(3,'last','d')])));
 assert.deepEqual(result.rejections,[{ordinal:2,code:'task.refused'}]);assert.equal(await count('business_task'),3);assert.equal(result.requiredCheckpoints[0].syncId,3);
 assert.equal((await db.$queryRawUnsafe("SELECT * FROM business_task WHERE id='c'")).length,0);
});
test('rejected mutation publishes nothing even though it called notify first',async()=>{
 const head=(await pull()).toCursor;
 const result=JSON.parse(await backend.push('alice',push('refuse-only',1,[mutation(1,'refuse','refuse-only-a')])));
 assert.deepEqual(result.rejections,[{ordinal:1,code:'task.refused'}]);
 assert.equal((await pull()).toCursor,head);
});
test('unknown error rolls back entire batch including earlier effects and client claim',async()=>{
 const head=(await pull()).toCursor;
 await assert.rejects(()=>backend.push('alice',push('crash',1,[mutation(1,'before','e'),mutation(2,'crash','f')])),/business crash/);
 assert.equal(await count('business_task'),3);assert.equal((await pull()).toCursor,head);assert.equal((await db.$queryRawUnsafe("SELECT * FROM ahead_client WHERE client_id='crash'")).length,0);
});
test('unsupported versions abort before handlers, invalid bodies settle with empty checkpoints',async()=>{
 const before=called;await assert.rejects(()=>backend.push('alice',push('version',1,[mutation(1,'ignored','v'),{...mutation(2,'bad','w'),version:2}])),error=>error instanceof EngineError&&error.code==='mutation_version_unsupported'&&error.details.ordinal===2&&error.details.name==='edit'&&error.details.version===2);assert.equal(called,before);
 const result=JSON.parse(await backend.push('alice',push('invalid',1,[{ordinal:1,name:'absent',operations:[]}])));assert.deepEqual(result,{requiredCheckpoints:[],requiredScope:'',requiredSyncId:0,rejections:[{ordinal:1,code:'mutation.invalid'}]});
});
test('loaders receive the channel whose pull requested the rows',async()=>{
 seenChannels.length=0;await pull('shared',0);assert.ok(seenChannels.length>0);assert.ok(seenChannels.every(c=>c==='shared'));
});
test('a pull reaches the loader of the served model version and normalizes rows with that contract',async()=>{
 // Task v2 adds a nullable `note`; v1 keeps {id, title}. Until clients declare a
 // version, the schema's own version (v2 here) is served, by its own loader.
 const c=structuredClone(config);c.mutations=[];c.schema.models[0].version=2;
 const v1={name:'Task',version:1,identity:['id'],fields:schema.models[0].fields,enums:[]};
 c.schema.models[0].fields=[...schema.models[0].fields,{name:'note',type:{kind:'scalar',name:'string'},nullable:true}];
 const v2={name:'Task',version:2,identity:['id'],fields:c.schema.models[0].fields,enums:[]};
 c.models=[v1,v2];
 const reached=[];
 const versioned=createBackend({config:c,database:prisma(db),authenticate,handlers:{},loaders:{task:{
  async v1({ids}){reached.push(1);return ids.map(id=>({id:id.id,title:'old'}))},
  async v2({ids}){reached.push(2);return ids.map(id=>({id:id.id,title:'new',note:'n'}))},
 }}});
 const page=await versioned.pull('alice',JSON.stringify({clientId:'c',scope:'shared',fromCursor:0}));
 const changes=JSON.parse(page).changes.filter(ch=>ch.state!==null);
 assert.ok(changes.length>0);assert.deepEqual(changes[0].state,{title:'new',note:'n'});
 assert.deepEqual([...new Set(reached)],[2],"only the served version's loader ran");
 // A row outside the served contract is a loader defect, not silently trimmed.
 const wide=createBackend({config:c,database:prisma(db),authenticate,handlers:{},loaders:{task:{
  async v1({ids}){return ids.map(id=>({id:id.id,title:'old'}))},
  async v2({ids}){return ids.map(id=>({id:id.id,title:'new',note:'n',extra:true}))},
 }}});
 await assert.rejects(()=>wide.pull('alice',JSON.stringify({clientId:'c',scope:'shared',fromCursor:0})),/unknown|state field/);
});
test('compaction materializes latest state; deletion is aligned null',async()=>{
 await backend.push('alice',push('dedup',2,[mutation(1,'updated')]));await assert.rejects(()=>backend.push('alice',push('dedup',1,[mutation(1,'first')])),/overlap/);
 await db.$transaction(async tx=>{await tx.$executeRawUnsafe("DELETE FROM business_task WHERE id='a'");await backend.notify(tx,{channel:'shared',records:[{model:'Task',identity:{id:'a'}}]});});
 const page=await pull();assert.equal(page.changes.length,3);assert.deepEqual(page.changes.at(-1).state,null);assert.equal(page.toCursor,5);
 await assert.rejects(()=>pull('shared',999),/cursor ahead/);
});
test('50-row pages retain original cursor progression and remainder reaches head',async()=>{
 await db.$transaction(async tx=>{for(let i=0;i<51;i++){await tx.$executeRawUnsafe('INSERT INTO business_task(id,title) VALUES($1,$2)',`page-${i}`,'page');await backend.notify(tx,{channel:'shared',records:[{model:'Task',identity:{id:`page-${i}`}}]});}},{timeout:20000});
 const first=await pull('shared',5);assert.equal(first.changes.length,50);assert.equal(first.toCursor,55);const last=await pull('shared',55);assert.equal(last.changes.length,1);assert.equal(last.toCursor,56);
});
test('concurrent same-client retry executes once under PostgreSQL lock',async()=>{const before=called;const request=push('race',1,[mutation(1,'race','race')]);const receipts=await Promise.all([backend.push('alice',request),backend.push('alice',request)]);assert.equal(receipts[0],receipts[1]);assert.equal(called,before+1);});
test('publication rollback uses user transaction and rejects unregistered models',async()=>{const before=(await pull('shared',56)).toCursor;await assert.rejects(()=>db.$transaction(async tx=>{await backend.notify(tx,{channel:'shared',records:[{model:'Task',identity:{id:'rollback'}}]});throw new Error('cancel');}),/cancel/);assert.equal((await pull('shared',56)).toCursor,before);await assert.rejects(()=>db.$transaction(tx=>backend.notify(tx,{channel:'shared',records:[{model:'Unknown',identity:{id:'x'}}]})),/unregistered loader/);});
test('loader defects abort pull instead of silently advancing its cursor',async()=>{
 const make=load=>createBackend({config:{...config,mutations:[]},database:prisma(db),authenticate,handlers:{},loaders:{task:load}});
 await assert.rejects(()=>make(async()=>[]).pull('alice',JSON.stringify({clientId:'c',scope:'shared',fromCursor:56})),/misaligned loader/);
 await assert.rejects(()=>make(async({ids})=>ids.map(()=>({title:'x',unexpected:true}))).pull('alice',JSON.stringify({clientId:'c',scope:'shared',fromCursor:56})),/unknown|state field/);
});
test('registered translator rejects one mutation; malformed translator code aborts transaction',async()=>{
 const make=code=>createBackend({config,database:prisma(db),authenticate,translateRejection:()=>code,handlers:{async edit({tx}){await tx.$executeRawUnsafe("INSERT INTO business_task(id,title) VALUES('translated','temporary')");throw new Error('product refusal');}},loaders:{async task(){return []}}});
 const receipt=JSON.parse(await make('product.denied').push('alice',push('translated',1,[mutation(1,'x')])));assert.deepEqual(receipt.rejections,[{ordinal:1,code:'product.denied'}]);assert.equal((await db.$queryRawUnsafe("SELECT * FROM business_task WHERE id='translated'")).length,0);
 await assert.rejects(()=>make('Not a machine code').push('alice',push('bad-translator',1,[mutation(1,'x')])),/stable machine code/);assert.equal((await db.$queryRawUnsafe("SELECT * FROM ahead_client WHERE client_id='bad-translator'")).length,0);
});

test('HTTP adapter authenticates and serves the real native persistence path',async()=>{
 const server=await backend.listen({port:0});const url=server.url;
 try {
  const denied=await fetch(`${url}/sync/pull`,{method:'POST',body:JSON.stringify({clientId:'c',scope:'shared',fromCursor:0})});assert.equal(denied.status,401);
  const result=await fetch(`${url}/sync/mutations`,{method:'POST',headers:{authorization:'Bearer alice'},body:push('http',1,[mutation(1,'network','http')])});assert.equal(result.status,200);assert.deepEqual((await result.json()).rejections,[]);
  const page=await fetch(`${url}/sync/pull`,{method:'POST',headers:{authorization:'Bearer alice'},body:JSON.stringify({clientId:'c',scope:'shared',fromCursor:57})});assert.equal(page.status,200);assert.equal((await page.json()).changes[0].state.title,'network');
  const bad=await fetch(`${url}/sync/pull`,{method:'POST',headers:{authorization:'Bearer alice'},body:'{'});assert.equal(bad.status,400);
 }finally{await server.close();}
});
test('undefined loader entries remain defects and never become tombstones',async()=>{
 const bad=createBackend({config:{...config,mutations:[]},database:prisma(db),authenticate,handlers:{},loaders:{async task({ids}){return ids.map(()=>undefined)}}});
 await assert.rejects(()=>bad.pull('alice',JSON.stringify({clientId:'c',scope:'shared',fromCursor:56})),/undefined|invalid loader/);
});
test('publication failures poison push and roll back business writes',async()=>{
 const broken=createBackend({config,database:prisma(db),authenticate,handlers:{async edit({tx,notify}){await tx.$executeRawUnsafe("INSERT INTO business_task(id,title) VALUES('caught','bad')");notify({channel:'shared',records:[{model:'Unknown',identity:{id:'caught'}}]});}},loaders:{async task(){return []}}});
 await assert.rejects(()=>broken.push('alice',push('caught',1,[mutation(1,'x')])),/unregistered loader/);
 assert.equal((await db.$queryRawUnsafe("SELECT * FROM business_task WHERE id='caught'")).length,0);assert.equal((await db.$queryRawUnsafe("SELECT * FROM ahead_client WHERE client_id='caught'")).length,0);
});
test('nonfinite nullable loader values are defects rather than null clears',async()=>{
 const expanded=structuredClone(config);expanded.schema.models[0].fields.push({name:'score',type:{kind:'scalar',name:'float'},nullable:true});
 expanded.mutations=[];const bad=createBackend({config:expanded,database:prisma(db),authenticate,handlers:{},loaders:{async task({ids}){return ids.map(()=>({title:'x',score:NaN}))}}});
 await assert.rejects(()=>bad.pull('alice',JSON.stringify({clientId:'c',scope:'shared',fromCursor:56})),/nonfinite/);
});
test('pending unawaited publication prevents outer transaction commit',async()=>{
 const bad=createBackend({config,database:{transaction:prismaTransactions(db),persistence:tx=>{const storage=new PrismaPersistence(tx);return {call:async r=>{if(r.op==='publish')await new Promise(resolve=>setTimeout(resolve,30));return storage.call(r);}}}},authenticate,handlers:{async edit(){}},loaders:{async task(){return []}}});
 await assert.rejects(()=>db.$transaction(async tx=>{const session=bad.bindTransaction(tx);try{await tx.$executeRawUnsafe("INSERT INTO business_task(id,title) VALUES('unawaited','bad')");void session.notify({channel:'shared',records:[{model:'Task',identity:{id:'unawaited'}}]});await session.assertCommittable();}finally{session.close();}}),/unawaited/);
 assert.equal((await db.$queryRawUnsafe("SELECT * FROM business_task WHERE id='unawaited'")).length,0);
});
test('external transaction binding retains swallowed publication failure until its completion gate',async()=>{
 await assert.rejects(()=>db.$transaction(async tx=>{const session=backend.bindTransaction(tx);try{await tx.$executeRawUnsafe("INSERT INTO business_task(id,title) VALUES('external','bad')");try{await session.notify({channel:'shared',records:[{model:'Unknown',identity:{id:'x'}}]});}catch{}await session.assertCommittable();}finally{session.close();}}),/unregistered loader/);
 assert.equal((await db.$queryRawUnsafe("SELECT * FROM business_task WHERE id='external'")).length,0);
});
test('repeatable-read runner keeps head, scan, and loader coherent across concurrent publication',async()=>{
 await db.$transaction(tx=>backend.notify(tx,{channel:'snapshot',records:[{model:'Task',identity:{id:'a'}}]}));let changed=false;
 const reader=createBackend({config:{...config,mutations:[]},database:{transaction:prismaTransactions(db),persistence:tx=>{const storage=new PrismaPersistence(tx);return {call:async r=>{const result=await storage.call(r);if(r.op==='head'&&!changed){changed=true;await db.$transaction(other=>backend.notify(other,{channel:'snapshot',records:[{model:'Task',identity:{id:'b'}}]}));}return result;}}}},authenticate,handlers:{},loaders:{async task({ids}){return ids.map(()=>null)}}});
 const page=JSON.parse(await reader.pull('alice',JSON.stringify({clientId:'c',scope:'snapshot',fromCursor:0})));assert.equal(page.toCursor,1);assert.equal(page.changes.length,1);
 const next=JSON.parse(await reader.pull('alice',JSON.stringify({clientId:'c',scope:'snapshot',fromCursor:1})));assert.equal(next.toCursor,2);assert.equal(next.changes.length,1);
});

const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const openSocket=async port=>{
 const socket=new serverSdk.WebSocket(`ws://127.0.0.1:${port}/sync/live`,{headers:{authorization:'Bearer alice'}});
 await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
 return socket;
};
const nextMessage=socket=>new Promise((resolve,reject)=>{
 const timer=setTimeout(()=>{cleanup();reject(new Error('timed out waiting for live frame'));},2000);
 const message=event=>{cleanup();resolve(JSON.parse(String(event.data)));};
 const closed=()=>{cleanup();reject(new Error('socket closed before frame'));};
 const cleanup=()=>{clearTimeout(timer);socket.removeEventListener('message',message);socket.removeEventListener('close',closed);};
 socket.addEventListener('message',message);socket.addEventListener('close',closed);
});

test('live transport negotiates, wakes only after commit, reconnects, and cleans up',async()=>{
 const server=await backend.listen({port:0});const port=Number(new URL(server.url).port);
 const socket=await openSocket(port);const frames=[];socket.addEventListener('message',event=>frames.push(JSON.parse(String(event.data))));
 socket.send(JSON.stringify({type:'subscribe',scopes:['shared','bob','shared']}));
 while(frames.length<1)await delay(5);
 assert.deepEqual(frames[0],{rejections:[],scopes:['bob','shared'],type:'subscribed'});

 let release,ready;const held=new Promise(resolve=>{release=resolve;});const started=new Promise(resolve=>{ready=resolve;});let notify;
 const committing=db.$transaction(async tx=>{const session=backend.bindTransaction(tx);try{
   await tx.$executeRawUnsafe("INSERT INTO business_task(id,title) VALUES('live-external','committed')");
   await session.notify({channel:'shared',records:[{model:'Task',identity:{id:'live-external'}}]});notify=session.afterCommit();ready();await held;await session.assertCommittable();
 }finally{session.close();}});
 await started;await delay(80);assert.equal(frames.length,1,'uncommitted publication must stay silent');release();await committing;await delay(50);assert.equal(frames.length,1,'commit alone requires the explicit external after-commit hook');notify();
 while(frames.length<2)await delay(5);
 assert.deepEqual(frames[1].changes.at(-1),{syncId:frames[1].toCursor,model:'Task',identity:{id:'live-external'},stamp:1,state:{title:'committed'}});

 const pageStart=frames.length;let notifyPages;
 await db.$transaction(async tx=>{const session=backend.bindTransaction(tx);try{for(let i=0;i<51;i++){const id=`live-page-${i}`;await tx.$executeRawUnsafe('INSERT INTO business_task(id,title) VALUES($1,$2)',id,'paged');await session.notify({channel:'shared',records:[{model:'Task',identity:{id}}]});}await session.assertCommittable();notifyPages=session.afterCommit();}finally{session.close();}},{timeout:20000});notifyPages();
 while(frames.length<pageStart+2)await delay(5);assert.equal(frames[pageStart].changes.length,50);assert.equal(frames[pageStart+1].changes.length,1);assert.equal(frames[pageStart+1].fromCursor,frames[pageStart].toCursor);

 const beforeRollback=frames.length;
 await assert.rejects(()=>db.$transaction(async tx=>{const session=backend.bindTransaction(tx);try{await session.notify({channel:'shared',records:[{model:'Task',identity:{id:'live-rollback'}}]});throw new Error('rollback live');}finally{session.close();}}),/rollback live/);
 await delay(80);assert.equal(frames.length,beforeRollback);

 socket.close();await new Promise(resolve=>socket.addEventListener('close',resolve,{once:true}));
 const reconnected=await openSocket(port);reconnected.send(JSON.stringify({type:'subscribe',scopes:['shared']}));await nextMessage(reconnected);
 const pagePromise=nextMessage(reconnected);await backend.push('alice',push('live-push',1,[mutation(1,'from push','live-push')]));
 const page=await pagePromise;assert.deepEqual(page.changes.at(-1).state,{title:'from push'});
 const afterPush=[];reconnected.addEventListener('message',event=>afterPush.push(event));await backend.push('alice',push('live-push',1,[mutation(1,'from push','live-push')]));
 await delay(80);assert.equal(afterPush.length,0,'duplicate receipt must not wake live subscribers');
 const protocol=await openSocket(port);protocol.send(JSON.stringify({type:'subscribe',scopes:['shared']}));await nextMessage(protocol);protocol.send('{}');
 const closeCode=await new Promise(resolve=>protocol.addEventListener('close',event=>resolve(event.code),{once:true}));assert.equal(closeCode,1002);
 reconnected.close();await new Promise(resolve=>reconnected.addEventListener('close',resolve,{once:true}));
 await server.close();
});

test('a publication committed between negotiation and the acknowledgement is delivered by the first drain',async()=>{
 // The negotiation transaction commits, then the wrapper holds the result on a
 // gate; a push commits meanwhile, before any listener exists for the socket.
 const base=prisma(db);let hold;
 const gated={transaction:async body=>{const result=await base.transaction(body);const gate=hold;hold=undefined;if(gate)await gate;return result;},persistence:base.persistence};
 const gatedBackend=createBackend({config,database:gated,authenticate,handlers:{async edit({input,tx,notify}){const {identity,patch}=input.task;await tx.$executeRawUnsafe('INSERT INTO business_task(id,title) VALUES($1,$2) ON CONFLICT(id) DO UPDATE SET title=$2',identity.id,patch.title);notify({channel:'shared',records:[input.task]});}},loaders:{async task({ids,tx}){return Promise.all(ids.map(async identity=>{const rows=await tx.$queryRawUnsafe('SELECT title FROM business_task WHERE id=$1',identity.id);return rows[0]??null;}));}}});
 const server=await gatedBackend.listen({port:0});const port=Number(new URL(server.url).port);
 try{
  const socket=await openSocket(port);const frames=[];socket.addEventListener('message',event=>frames.push(JSON.parse(String(event.data))));
  let release;hold=new Promise(resolve=>{release=resolve;});
  socket.send(JSON.stringify({type:'subscribe',scopes:['shared']}));
  await delay(100);assert.equal(frames.length,0,'the acknowledgement is held on the gate');
  await gatedBackend.push('alice',push('between',1,[mutation(1,'between negotiation and ack','live-between')]));
  await delay(50);assert.equal(frames.length,0,'no listener exists yet, so the commit wakes nobody');
  release();
  while(frames.length<2)await delay(5);
  assert.deepEqual(frames[0],{rejections:[],scopes:['shared'],type:'subscribed'});
  assert.deepEqual(frames[1].changes.at(-1),{syncId:frames[1].toCursor,model:'Task',identity:{id:'live-between'},stamp:1,state:{title:'between negotiation and ack'}});
  socket.close();await new Promise(resolve=>socket.addEventListener('close',resolve,{once:true}));
 }finally{await server.close();}
});
test('loader safely converts PostgreSQL BigInt scalar and list values without widening wire range', async () => {
  const int = {kind: 'scalar', name: 'int'};
  let value = 9007199254740991n;
  const bigintBackend = createBackend({
    config: {mutations: [], schema: {enums: [], models: [{name: 'Counter', identity: ['id'], fields: [
      {name: 'id', type: {kind: 'scalar', name: 'string'}, nullable: false},
      {name: 'count', type: int, nullable: false},
      {name: 'counts', type: {kind: 'list', element: int}, nullable: false},
    ]}]}},
    database: prisma(db), authenticate,
    handlers: {},
    loaders: {async counter({tx}) {return tx.$queryRawUnsafe(
      'SELECT $1::bigint AS count, ARRAY[$1::bigint,(-$1)::bigint] AS counts', value,
    )}},
  });
  await db.$transaction(tx => bigintBackend.notify(tx, {channel: 'bigints', records: [{model: 'Counter', identity: {id: 'one'}}]}));
  const request = JSON.stringify({clientId: 'bigint-reader', scope: 'bigints', fromCursor: 0});
  let page = JSON.parse(await bigintBackend.pull('alice', request));
  assert.deepEqual(page.changes[0].state, {count: Number.MAX_SAFE_INTEGER, counts: [Number.MAX_SAFE_INTEGER, -Number.MAX_SAFE_INTEGER]});
  value = -9007199254740991n;
  page = JSON.parse(await bigintBackend.pull('alice', request));
  assert.equal(page.changes[0].state.count, -Number.MAX_SAFE_INTEGER);
  for (const overflow of [9007199254740992n, -9007199254740992n]) {
    value = overflow;
    await assert.rejects(bigintBackend.pull('alice', request), /bigint outside safe integer range/);
  }
});
test('prisma() bundles the transaction runner and the persistence factory',async()=>{
 const adapter=prisma(db);
 assert.equal(typeof adapter.transaction,'function');
 const bound=adapter.persistence({$queryRawUnsafe:async()=>[{head:7}],$executeRawUnsafe:async()=>1});
 assert.equal(await bound.call({op:'head',channel:'x'}),7);
});
test('listen answers pull over HTTP with authentication and closes cleanly',async()=>{
 const server=await backend.listen({port:0});
 try{
  const denied=await fetch(`${server.url}/sync/pull`,{method:'POST',body:'{}'});assert.equal(denied.status,401);
  const ok=await fetch(`${server.url}/sync/pull`,{method:'POST',headers:{authorization:'Bearer alice'},body:JSON.stringify({clientId:'listen',scope:'shared',fromCursor:0})});assert.equal(ok.status,200);
 }finally{await server.close();}
});
test('onError captures server-side failures and HTTP responds with {code:"server"}',async()=>{
 const errors=[];
 const boomBackend=createBackend({config,database:prisma(db),authenticate,onError:e=>errors.push(e),handlers:{async edit(){throw new Error('boom')}},loaders:{async task({ids}){return ids.map(()=>null)}}});
 const server=await boomBackend.listen({port:0});
 try{
  const result=await fetch(`${server.url}/sync/mutations`,{method:'POST',headers:{authorization:'Bearer alice'},body:push('boom',1,[mutation(1,'x','boom-a')])});
  assert.equal(result.status,500);
  assert.deepEqual(await result.json(),{code:'server'});
  assert.equal(errors.length,1);
  assert.equal(errors[0].message,'boom');
 }finally{await server.close();}
});
test('slot arguments are tagged so notify accepts them directly',async()=>{
 await backend.push('alice',push('tagged',1,[mutation(1,'hello','tagged-a')]));
 assert.deepEqual(lastInput.task[RECORD],{model:'Task',identity:{id:'tagged-a'}});
 assert.deepEqual(Object.keys(lastInput.task),['identity','patch']);
 assert.equal(RECORD in {...lastInput.task},false);
});
test('checkpoint is the single notified channel; several need an explicit choice; none is an error',async()=>{
 const one=JSON.parse(await backend.push('alice',push('cp1',1,[mutation(1,'hello','cp-a')])));
 assert.deepEqual(one.requiredCheckpoints.map(c=>c.scope),['shared']);
 await assert.rejects(()=>backend.push('alice',push('cp2',1,[mutation(1,'two','cp-b')])),/handler\.ambiguous_checkpoint:edit/);
 const picked=JSON.parse(await backend.push('alice',push('cp3',1,[mutation(1,'pick','cp-c')])));
 assert.deepEqual(picked.requiredCheckpoints.map(c=>c.scope),['other']);
 const silent=createBackend({config,database:prisma(db),authenticate,handlers:{async edit(){}},loaders:{async task({ids}){return ids.map(()=>null)}}});
 await assert.rejects(()=>silent.push('alice',push('cp4',1,[mutation(1,'hello','cp-d')])),/handler\.no_channel:edit/);
 await assert.rejects(()=>backend.push('alice',push('cp5',1,[mutation(1,'empty-checkpoint','cp-e')])),/handler\.invalid_checkpoint:edit/);
 await assert.rejects(()=>backend.push('alice',push('cp6',1,[mutation(1,'never-checkpoint','cp-f')])),/handler\.unnotified_checkpoint:edit/);
});
test('checkpoint errors bypass translateRejection and abort the batch instead of settling as a rejection',async()=>{
 const silentTranslated=createBackend({config,database:prisma(db),authenticate,translateRejection:()=>'task.translated',handlers:{async edit(){}},loaders:{async task({ids}){return ids.map(()=>null)}}});
 await assert.rejects(()=>silentTranslated.push('alice',push('cp-none-t',1,[mutation(1,'hello','cp-none-t')])),/handler\.no_channel:edit/);
 const ambiguousTranslated=createBackend({config,database:prisma(db),authenticate,translateRejection:()=>'task.translated',handlers:{async edit({input,tx,notify}){const {identity,patch}=input.task;await tx.$executeRawUnsafe('INSERT INTO business_task(id,title) VALUES($1,$2) ON CONFLICT(id) DO UPDATE SET title=$2',identity.id,patch.title);notify({channel:'shared',records:[input.task]});notify({channel:'other',records:[input.task]});}},loaders:{async task({ids,tx}){return Promise.all(ids.map(async identity=>{const rows=await tx.$queryRawUnsafe('SELECT title FROM business_task WHERE id=$1',identity.id);return rows[0]??null;}));}}});
 await assert.rejects(()=>ambiguousTranslated.push('alice',push('cp-amb-t',1,[mutation(1,'x','cp-amb-t')])),/handler\.ambiguous_checkpoint:edit/);
});
test('notify validates channel and records before dispatching to native publish',async()=>{
 await assert.rejects(()=>backend.push('alice',push('badchan',1,[mutation(1,'empty-channel','bad-a')])),/notify: channel must be a non-empty string/);
 await assert.rejects(()=>backend.push('alice',push('badrecs',1,[mutation(1,'bad-records','bad-b')])),/notify: records must be an array/);
 await assert.rejects(()=>backend.push('alice',push('badbogus',1,[mutation(1,'bogus-record','bad-c')])),/notify: record must be/);
});
test('handler awaiting the tx after notify still drains pending publication before checkpoint',async()=>{
 const deferredBackend=createBackend({config,database:prisma(db),authenticate,handlers:{async edit({input,tx,notify}){
  const {identity,patch}=input.task;
  await tx.$executeRawUnsafe('INSERT INTO business_task(id,title) VALUES($1,$2) ON CONFLICT(id) DO UPDATE SET title=$2',identity.id,patch.title);
  notify({channel:'deferred',records:[input.task]});
  await tx.$queryRawUnsafe('SELECT 1');
 }},loaders:{async task({ids,tx}){return Promise.all(ids.map(async identity=>{const rows=await tx.$queryRawUnsafe('SELECT title FROM business_task WHERE id=$1',identity.id);return rows[0]??null;}));}}});
 const receipt=JSON.parse(await deferredBackend.push('alice',push('deferred',1,[mutation(1,'deferred','deferred-a')])));
 assert.deepEqual(receipt.rejections,[]);
 assert.deepEqual(receipt.requiredCheckpoints.map(c=>c.scope),['deferred']);
 const page=JSON.parse(await deferredBackend.pull('alice',JSON.stringify({clientId:'deferred-reader',scope:'deferred',fromCursor:0})));
 assert.equal(page.changes.at(-1).identity.id,'deferred-a');
 assert.equal(page.changes.at(-1).state.title,'deferred');
});
test('an all-rejected batch settles with no checkpoints',async()=>{
 const receipt=JSON.parse(await backend.push('alice',push('allrej',1,[mutation(1,'refuse','rej-a')])));
 assert.deepEqual(receipt.requiredCheckpoints,[]);assert.equal(receipt.requiredScope,'');assert.equal(receipt.rejections.length,1);
});
test('publish allocates one stamp per notify and stores it on the invalidation row',async()=>{
 const stamps=await db.$transaction(async tx=>{const storage=new PrismaPersistence(tx);const ref={model:'Task',identity:{id:'stamped'},identityKey:'{"id":"stamped"}'};
  const a=await storage.call({op:'publish',channel:'stamp-a',...ref});const b=await storage.call({op:'publish',channel:'stamp-b',...ref});const a2=await storage.call({op:'publish',channel:'stamp-a',...ref});return [a,b,a2];});
 assert.deepEqual(stamps.map(s=>s.stamp),[1,2,3]);assert.deepEqual(stamps.map(s=>s.cursor),[1,1,2]);
 const record=await db.$queryRawUnsafe(`SELECT stamp FROM ahead_record WHERE model='Task' AND identity_key='{"id":"stamped"}'`);assert.equal(Number(record[0].stamp),3);
 const rows=await db.$queryRawUnsafe(`SELECT channel, cursor, stamp FROM ahead_invalidation WHERE identity_key='{"id":"stamped"}' ORDER BY channel`);
 assert.deepEqual(rows.map(r=>[r.channel,Number(r.cursor),Number(r.stamp)]),[['stamp-a',2,3],['stamp-b',1,2]]);
});
test('scan returns the stamp of each row',async()=>{
 const rows=await db.$transaction(tx=>new PrismaPersistence(tx).call({op:'scan',channel:'stamp-a',after:0,limit:50}));
 assert.deepEqual(rows.map(r=>[r.cursor,r.stamp]),[[2,3]]);
});
test('concurrent notifies of one record receive distinct stamps',async()=>{
 const notify=()=>db.$transaction(async tx=>{await backend.notify(tx,{channel:'race-stamp',records:[{model:'Task',identity:{id:'stamp-race'}}]});});
 await Promise.all([notify(),notify(),notify(),notify()]);
 const record=await db.$queryRawUnsafe(`SELECT stamp FROM ahead_record WHERE model='Task' AND identity_key='{"id":"stamp-race"}'`);assert.equal(Number(record[0].stamp),4);
 const page=await pull('race-stamp',0);assert.equal(page.changes.length,1);assert.equal(page.changes[0].stamp,4);
});
import {createServer as createProxyServer,request as httpRequest} from 'node:http';
import {connect as tcpConnect} from 'node:net';
/** A minimal reverse proxy: plain HTTP forwarding plus a TCP pass-through of the WebSocket upgrade, optionally stripping headers. */
async function reverseProxy(upstreamUrl,{strip=[]}={}){
 const target=new URL(upstreamUrl);
 const forwardHeaders=headers=>{const copy={...headers};for(const name of strip)delete copy[name];return copy;};
 const proxy=createProxyServer((req,res)=>{
  const out=httpRequest({host:target.hostname,port:target.port,method:req.method,path:req.url,headers:forwardHeaders(req.headers)},up=>{res.writeHead(up.statusCode,up.headers);up.pipe(res);});
  out.on('error',()=>{res.statusCode=502;res.end();});req.pipe(out);
 });
 proxy.on('upgrade',(req,socket,head)=>{
  const upstream=tcpConnect(Number(target.port),target.hostname,()=>{
   const lines=[`${req.method} ${req.url} HTTP/1.1`,...Object.entries(forwardHeaders(req.headers)).map(([k,v])=>`${k}: ${Array.isArray(v)?v.join(', '):v}`)];
   upstream.write(lines.join('\r\n')+'\r\n\r\n');if(head.length)upstream.write(head);
   socket.pipe(upstream);upstream.pipe(socket);
  });
  upstream.on('error',()=>socket.destroy());socket.on('error',()=>upstream.destroy());
 });
 await new Promise(resolve=>proxy.listen(0,'127.0.0.1',resolve));
 return {url:`http://127.0.0.1:${proxy.address().port}`,close:()=>new Promise(resolve=>{proxy.closeAllConnections();proxy.close(()=>resolve());})};
}
test('a reverse proxy forwarding HTTP and the WebSocket upgrade with headers serves push, pull and live; a stripped Authorization header is refused',async()=>{
 const server=await backend.listen({port:0});const proxy=await reverseProxy(server.url);
 try{
  const pushed=await fetch(`${proxy.url}/sync/mutations`,{method:'POST',headers:{authorization:'Bearer alice'},body:push('proxied',1,[mutation(1,'through proxy','proxy-a')])});
  assert.equal(pushed.status,200);assert.deepEqual((await pushed.json()).rejections,[]);
  const seen=[];for(let fromCursor=0;;){const page=await fetch(`${proxy.url}/sync/pull`,{method:'POST',headers:{authorization:'Bearer alice'},body:JSON.stringify({clientId:'c',scope:'shared',fromCursor})});
   assert.equal(page.status,200);const body=await page.json();seen.push(...body.changes);if(body.changes.length<50)break;fromCursor=body.toCursor;}
  assert.ok(seen.some(c=>c.identity.id==='proxy-a'&&c.state.title==='through proxy'),'the pushed record is pulled through the proxy');
  const socket=new serverSdk.WebSocket(`${proxy.url.replace('http','ws')}/sync/live`,{headers:{authorization:'Bearer alice'}});
  await new Promise((resolve,reject)=>{socket.on('open',resolve);socket.on('error',reject);});
  const frames=[];socket.on('message',data=>frames.push(JSON.parse(String(data))));
  socket.send(JSON.stringify({type:'subscribe',scopes:['shared']}));while(frames.length<1)await delay(5);
  assert.equal(frames[0].type,'subscribed');
  await backend.push('alice',push('proxied',2,[mutation(2,'live through proxy','proxy-a')]));
  while(frames.length<2)await delay(5);assert.equal(frames.at(-1).changes.at(-1).state.title,'live through proxy');
  socket.close();await new Promise(resolve=>socket.on('close',resolve));
  const stripping=await reverseProxy(server.url,{strip:['authorization']});
  try{
   const denied=await fetch(`${stripping.url}/sync/pull`,{method:'POST',headers:{authorization:'Bearer alice'},body:'{}'});assert.equal(denied.status,401);
   const refused=new serverSdk.WebSocket(`${stripping.url.replace('http','ws')}/sync/live`,{headers:{authorization:'Bearer alice'}});
   const failure=await new Promise(resolve=>{refused.on('error',resolve);refused.on('open',()=>resolve(null));});
   assert.ok(failure,'the upgrade is refused without the header');assert.match(String(failure.message),/401/);
  }finally{await stripping.close();}
 }finally{await proxy.close();await server.close();}
});
test('HTTP maps engine codes to statuses: 403, 409 gap/overlap/version fields, 404, 405, 413, 400',async()=>{
 const server=await backend.listen({port:0});const url=server.url;
 const post=(path,body,headers={authorization:'Bearer alice'})=>fetch(`${url}${path}`,{method:'POST',headers,body});
 try{
  await backend.push('alice',push('map',1,[mutation(1,'one','map-a')]));
  const gap=await post('/sync/mutations',push('map',5,[mutation(1,'x','map-a')]));assert.equal(gap.status,409);assert.deepEqual(await gap.json(),{code:'gap'});
  const overlap=await post('/sync/mutations',push('map',1,[mutation(9,'other','map-a')]));assert.equal(overlap.status,200,'a retry of the accepted sequence returns its receipt');
  await backend.push('alice',push('map',2,[mutation(2,'second','map-a')]));
  const behind=await post('/sync/mutations',push('map',1,[mutation(1,'one','map-a')]));assert.equal(behind.status,409);assert.deepEqual(await behind.json(),{code:'overlap'});
  const bobBackend=createBackend({config,database:prisma(db),authenticate:async req=>req.headers.authorization==='Bearer bob'?'bob':null,handlers:{async edit(){}},loaders:{async task({ids}){return ids.map(()=>null)}}});
  const bobServer=await bobBackend.listen({port:0});
  try{const owner=await fetch(`${bobServer.url}/sync/mutations`,{method:'POST',headers:{authorization:'Bearer bob'},body:push('map',3,[mutation(3,'x','map-a')])});assert.equal(owner.status,403);assert.deepEqual(await owner.json(),{code:'client.owner_mismatch'});}
  finally{await bobServer.close();}
  const version=await post('/sync/mutations',push('map',3,[{...mutation(3,'x','map-a'),version:7}]));assert.equal(version.status,409);
  assert.deepEqual(await version.json(),{code:'mutation_version_unsupported',ordinal:3,name:'edit',version:7});
  const ahead=await post('/sync/pull',JSON.stringify({clientId:'c',scope:'shared',fromCursor:1e9}));assert.equal(ahead.status,400);assert.deepEqual(await ahead.json(),{code:'request.invalid'});
  const array=await post('/sync/pull','[]');assert.equal(array.status,400);assert.deepEqual(await array.json(),{code:'request.invalid'});
  const missing=await post('/sync/nowhere','{}');assert.equal(missing.status,404);assert.deepEqual(await missing.json(),{code:'not_found'});
  const get=await fetch(`${url}/sync/pull`,{headers:{authorization:'Bearer alice'}});assert.equal(get.status,405);assert.equal(get.headers.get('allow'),'POST');assert.deepEqual(await get.json(),{code:'method_not_allowed'});
  const large=await post('/sync/pull',JSON.stringify({clientId:'c',scope:'shared',fromCursor:0,padding:'x'.repeat(1_048_577)}));assert.equal(large.status,413);assert.deepEqual(await large.json(),{code:'request_too_large'});
 }finally{await server.close();}
});
test('HTTP classifies native failures by code, not message wording; unknown codes fall back to 500',async()=>{
 const errors=[];
 const reason=(code,message,details)=>Object.assign(new Error(JSON.stringify({code,message,...(details?{details}:{})})),{});
 const fake={validateConfig(){},async processPush(){throw reason('gap','the batch sequence 5 skips ahead of 1 (reworded)');},async processPull(){throw reason('mutation_version_unsupported','anything',{ordinal:2,name:'edit',version:9});},async publish(){return '[]';},async negotiateLive(){throw reason('request.invalid','no');},async pullLive(){throw reason('loader.unregistered','unregistered loader');},liveEvent(){return '[]';},liveClose(){}};
 const memory={transaction:body=>body({}),persistence:()=>({call:async()=>null})};
 const fakeBackend=createBackend({config,database:memory,native:fake,authenticate,onError:e=>errors.push(e),handlers:{async edit(){}},loaders:{async task({ids}){return ids.map(()=>null)}}});
 await assert.rejects(()=>fakeBackend.push('alice','{}'),error=>error instanceof EngineError&&error.code==='gap'&&error.message.includes('reworded'));
 const server=await fakeBackend.listen({port:0});
 try{
  const gap=await fetch(`${server.url}/sync/mutations`,{method:'POST',headers:{authorization:'Bearer alice'},body:'{}'});assert.equal(gap.status,409);assert.deepEqual(await gap.json(),{code:'gap'});
  const version=await fetch(`${server.url}/sync/pull`,{method:'POST',headers:{authorization:'Bearer alice'},body:'{}'});assert.equal(version.status,409);assert.deepEqual(await version.json(),{code:'mutation_version_unsupported',ordinal:2,name:'edit',version:9});
  assert.equal(errors.length,0,'classified refusals are not server errors');
  const socket=new serverSdk.WebSocket(`${server.url.replace('http','ws')}/sync/live`,{headers:{authorization:'Bearer alice'}});
  const closed=await new Promise(resolve=>{socket.on('open',()=>socket.send(JSON.stringify({type:'subscribe',scopes:['shared']})));socket.on('close',(code,reasonText)=>resolve({code,reason:String(reasonText)}));socket.on('error',()=>{});});
  assert.equal(closed.code,1002);assert.equal(errors.length,0);
  fake.negotiateLive=async()=>JSON.stringify({handle:1,actions:[{type:'listen',scope:'shared'},{type:'send',frame:JSON.stringify({type:'subscribed',scopes:['shared'],rejections:[]})},{type:'pull',scope:'shared',fromCursor:0}]});
  const drained=new serverSdk.WebSocket(`${server.url.replace('http','ws')}/sync/live`,{headers:{authorization:'Bearer alice'}});
  const drainClose=await new Promise(resolve=>{drained.on('open',()=>drained.send(JSON.stringify({type:'subscribe',scopes:['shared']})));drained.on('close',code=>resolve(code));drained.on('error',()=>{});});
  assert.equal(drainClose,1011);assert.equal(errors.length,1);assert.ok(errors[0] instanceof EngineError);assert.equal(errors[0].code,'loader.unregistered');
  fake.processPush=async()=>{throw reason('storage.invalid','receipt missing');};
  const unknown=await fetch(`${server.url}/sync/mutations`,{method:'POST',headers:{authorization:'Bearer alice'},body:'{}'});assert.equal(unknown.status,500);assert.deepEqual(await unknown.json(),{code:'server'});
  assert.equal(errors.length,2);assert.equal(errors[1].code,'storage.invalid');assert.equal(errors[1].message,'receipt missing');
  fake.processPush=async()=>{throw new Error('not json at all');};
  const plain=await fetch(`${server.url}/sync/mutations`,{method:'POST',headers:{authorization:'Bearer alice'},body:'{}'});assert.equal(plain.status,500);
  assert.equal(errors.length,3);assert.ok(!(errors[2] instanceof EngineError));assert.equal(errors[2].message,'not json at all');
 }finally{await server.close();}
});
test('prismaTransactions retries only serialization failures, a bounded number of times, and reports the last one',async()=>{
 const attempts=[];const bodies=[];
 const failing=(codes)=>({async $transaction(body,options){attempts.push(options);const code=codes.shift();await body({attempt:attempts.length});bodies.push(attempts.length);if(code)throw Object.assign(new Error(`fail ${code.code}`),code);return 'committed';}});
 const conflict={code:'P2034'};const rawConflict={code:'P2010',meta:{code:'40001'}};const deadlock={code:'P2010',meta:{code:'40P01'}};const unique={code:'P2002'};
 assert.equal(await prismaTransactions(failing([conflict,rawConflict,deadlock]))(async()=>'body'),'committed','the fourth attempt succeeds within the default of three retries');
 assert.equal(attempts.length,4);assert.deepEqual(bodies,[1,2,3,4],'the body runs once per attempt');assert.deepEqual(attempts[0],{isolationLevel:'RepeatableRead',timeout:20000});
 attempts.length=0;bodies.length=0;
 await assert.rejects(()=>prismaTransactions(failing([conflict,conflict,conflict,conflict]))(async()=>{}),error=>error.code==='P2034'&&error.message==='fail P2034');
 assert.equal(attempts.length,4,'three retries after the first attempt, then the failure is reported');
 attempts.length=0;
 await assert.rejects(()=>prismaTransactions(failing([conflict,conflict]),{retries:1})(async()=>{}),error=>error.code==='P2034');
 assert.equal(attempts.length,2,'retries is the number of additional attempts');
 attempts.length=0;
 await assert.rejects(()=>prismaTransactions(failing([unique]))(async()=>{}),error=>error.code==='P2002');
 assert.equal(attempts.length,1,'a non-serialization failure is not retried');
 attempts.length=0;
 const bundled=prisma(failing([conflict]),{retries:1,timeout:5});await bundled.transaction(async()=>{});
 assert.deepEqual(attempts.map(o=>o.timeout),[5,5],'prisma() passes retries and timeout to the runner');
});
test('a RepeatableRead conflict on the real database retries the whole body once and commits it exactly once',async()=>{
 await db.$executeRawUnsafe("INSERT INTO ahead_channel(channel,head) VALUES('serial',0) ON CONFLICT(channel) DO UPDATE SET head=0");
 const run=prismaTransactions(db);let bodies=0;let entered,release;const inside=new Promise(resolve=>{entered=resolve;});const gate=new Promise(resolve=>{release=resolve;});
 const first=run(async tx=>{bodies++;const [{head}]=await tx.$queryRawUnsafe("SELECT head FROM ahead_channel WHERE channel='serial'");if(bodies===1){entered();await gate;}
  await tx.$executeRawUnsafe("UPDATE ahead_channel SET head=head+1 WHERE channel='serial'");return Number(head);});
 await inside;
 await db.$executeRawUnsafe("UPDATE ahead_channel SET head=head+10 WHERE channel='serial'");
 release();
 assert.equal(await first,10,'the retried body read the snapshot taken after the concurrent commit');
 assert.equal(bodies,2,'the first attempt failed with a serialization error after the concurrent update and the body ran again');
 assert.equal(Number((await db.$queryRawUnsafe("SELECT head FROM ahead_channel WHERE channel='serial'"))[0].head),11,'the rolled-back attempt left nothing behind and the retry committed once');
 const exhausted=prismaTransactions(db,{retries:0});bodies=0;let entered2,release2;const inside2=new Promise(resolve=>{entered2=resolve;});const gate2=new Promise(resolve=>{release2=resolve;});
 const second=exhausted(async tx=>{bodies++;await tx.$queryRawUnsafe("SELECT head FROM ahead_channel WHERE channel='serial'");entered2();await gate2;await tx.$executeRawUnsafe("UPDATE ahead_channel SET head=head+1 WHERE channel='serial'");});
 await inside2;await db.$executeRawUnsafe("UPDATE ahead_channel SET head=head+10 WHERE channel='serial'");release2();
 await assert.rejects(second,error=>error.code==='P2034'||(error.code==='P2010'&&error.meta?.code==='40001'));
 assert.equal(bodies,1);assert.equal(Number((await db.$queryRawUnsafe("SELECT head FROM ahead_channel WHERE channel='serial'"))[0].head),21,'with no retries the conflict is reported and the transaction leaves no trace');
});
test('an upgrade whose authentication completes after close begins is refused with 503; missing and invalid credentials are refused with 401',async()=>{
 let release;const gate=new Promise(resolve=>{release=resolve;});const seen=[];
 const gated=createBackend({config,database:prisma(db),authenticate:async req=>{seen.push(req.headers.authorization);if(req.headers.authorization==='Bearer slow'){await gate;return 'alice';}return req.headers.authorization==='Bearer alice'?'alice':null;},handlers:{async edit(){}},loaders:{async task({ids}){return ids.map(()=>null)}}});
 const server=await gated.listen({port:0});const ws=server.url.replace('http','ws');
 const refusal=socket=>new Promise(resolve=>{socket.on('error',error=>resolve(String(error.message)));socket.on('open',()=>resolve('open'));});
 try{
  assert.match(await refusal(new serverSdk.WebSocket(`${ws}/sync/live`)),/401/,'no credentials');
  assert.match(await refusal(new serverSdk.WebSocket(`${ws}/sync/live`,{headers:{authorization:'Bearer mallory'}})),/401/,'unknown credentials');
  const slow=new serverSdk.WebSocket(`${ws}/sync/live`,{headers:{authorization:'Bearer slow'}});const outcome=refusal(slow);
  while(!seen.includes('Bearer slow'))await delay(5);
  const closing=server.close();release();
  assert.match(await outcome,/503/,'authenticated after close began: refused, not served');
  await closing;
 }finally{await server.close();}
});

test('a version dispatches only to its own handler and a function registers v1',async()=>{
 const seen=[];
 const record=tag=>async({input,notify})=>{seen.push([tag,input.task.patch.title]);notify({channel:'registration',records:[input.task]});};
 const make=(handlers,mutations=config.mutations)=>createBackend({config:{...config,schema:structuredClone(schema),mutations},database:prisma(db),authenticate,handlers,loaders:{async task({ids}){return ids.map(()=>null)}}});
 const shorthand=JSON.parse(await make({edit:record('function')}).push('alice',push('register-function',1,[mutation(1,'same','reg-a')])));
 const explicit=JSON.parse(await make({edit:{v1:record('v1 key')}}).push('alice',push('register-v1-key',1,[mutation(1,'same','reg-a')])));
 assert.deepEqual(seen,[['function','same'],['v1 key','same']],'both registrations reach the same v1 handler');
 assert.deepEqual(shorthand.rejections,[]);assert.deepEqual(explicit.rejections,[]);
 assert.equal(shorthand.requiredScope,'registration');assert.equal(explicit.requiredScope,'registration');
 assert.equal(explicit.requiredSyncId,shorthand.requiredSyncId+1,'only the publication sequence differs');
 const two=make({edit:{v1:record('v1'),v2:record('v2')}},[config.mutations[0],{...config.mutations[0],version:2}]);
 await two.push('alice',push('register-dispatch',1,[mutation(1,'from v1','reg-b')]));
 await two.push('alice',push('register-dispatch',2,[{...mutation(1,'from v2','reg-c'),version:2}]));
 assert.deepEqual(seen.slice(2),[['v1','from v1'],['v2','from v2']],'no fallback between versions');
});
test('concurrent same-client delivery with different bodies commits at most one under the PostgreSQL lock',async()=>{
 const before=called;const shared=async()=>Number((await db.$queryRawUnsafe("SELECT head FROM ahead_channel WHERE channel='shared'"))[0].head);
 // A concurrent delivery of the same sequence with a different body commits at most one of the two: the loser waits on the row lock, then replays the winner's receipt.
 const head=await shared();const changed=push('race-body',1,[mutation(1,'winner','race-body')]);const other=push('race-body',1,[mutation(1,'loser','race-body')]);
 const pair=await Promise.all([backend.push('alice',changed),backend.push('alice',other)]);assert.equal(pair[0],pair[1]);assert.equal(called,before+1);
 assert.equal(await shared(),head+1,'exactly one publication');const [row]=await db.$queryRawUnsafe("SELECT title FROM business_task WHERE id='race-body'");assert.ok(['winner','loser'].includes(row.title));
 const [client]=await db.$queryRawUnsafe("SELECT sequence, receipt FROM ahead_client WHERE client_id='race-body'");assert.equal(Number(client.sequence),1);assert.equal(client.receipt,pair[0]);
});
test('fresh framework tables omit request_hash; a table that still carries the column keeps replaying receipts',async()=>{
 const columns=async()=>(await db.$queryRawUnsafe("SELECT column_name FROM information_schema.columns WHERE table_name='ahead_client'")).map(row=>row.column_name).sort();
 assert.deepEqual(await columns(),['client_id','owner_id','receipt','sequence']);
 const migration=(await readFile(new URL('../../../packages/persistence-prisma/migration.sql',import.meta.url),'utf8')).split(';').map(x=>x.trim()).filter(Boolean);
 const before=called;const request=push('legacy-column',1,[mutation(1,'legacy','legacy-column')]);let receipt;
 await db.$executeRawUnsafe('ALTER TABLE ahead_client ADD COLUMN request_hash text');
 try{
  for(const sql of migration)await db.$executeRawUnsafe(sql);
  assert.deepEqual(await columns(),['client_id','owner_id','receipt','request_hash','sequence'],'re-applying migration.sql leaves an existing table untouched');
  receipt=await backend.push('alice',request);assert.equal(await backend.push('alice',push('legacy-column',1,[mutation(1,'changed','legacy-column')])),receipt);assert.equal(called,before+1);
  const [row]=await db.$queryRawUnsafe("SELECT request_hash, sequence FROM ahead_client WHERE client_id='legacy-column'");assert.equal(row.request_hash,null);assert.equal(Number(row.sequence),1);
 }finally{await db.$executeRawUnsafe('ALTER TABLE ahead_client DROP COLUMN request_hash');}
 assert.deepEqual(await columns(),['client_id','owner_id','receipt','sequence']);
 assert.equal(await backend.push('alice',request),receipt,'the stored receipt survives dropping the unused column');assert.equal(called,before+1);
 await assert.rejects(()=>backend.push('alice',push('legacy-column',3,[mutation(2,'gap','legacy-column')])),/gap/);
 // Only the most recently committed sequence replays; once sequence 2 commits, sequence 1 is an overlap even with its original body.
 const next=await backend.push('alice',push('legacy-column',2,[mutation(2,'next','legacy-column')]));assert.notEqual(next,receipt);assert.equal(called,before+2);
 await assert.rejects(()=>backend.push('alice',request),/overlap/);assert.equal(await backend.push('alice',push('legacy-column',2,[mutation(2,'changed','legacy-column')])),next);assert.equal(called,before+2);
});
