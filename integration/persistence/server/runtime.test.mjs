import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import * as serverSdk from '../../../packages/server/index.mts';
import {createBackend,MutationRejected,RECORD} from '../../../packages/server/index.mts';
import {PrismaPersistence,prismaTransactions,prisma} from '../../../packages/persistence-prisma/index.mts';
const require=createRequire(import.meta.url);
const {PrismaClient}=require('../../bindings/node/generated/client');
const native=require('../../../bindings/node/otter-node.node');
const db=new PrismaClient();
const schema={enums:[],models:[{name:'Task',identity:['id'],fields:[{name:'id',type:{kind:'scalar',name:'string'},nullable:false},{name:'title',type:{kind:'scalar',name:'string'},nullable:false}]}]};
const config={schema,mutations:[{name:'edit',version:1,slots:[{name:'task',model:'Task',operation:'update',cardinality:'single',allowedPatchFields:['title']}]}]};
const authenticate=async req=>req.headers.authorization==='Bearer alice'?'alice':null;
let called=0,prepared=0,lastInput;
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
 loaders:{async task({ids,tx}){return Promise.all(ids.map(async identity=>{const rows=await tx.$queryRawUnsafe('SELECT title FROM business_task WHERE id=$1',identity.id);return rows[0]??null;}));}},
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
});
test('backend validates config and complete registrations at startup',()=>{
 const base={...config,schema:structuredClone(schema)};
 assert.throws(()=>createBackend({config:{...base,mutations:[{name:'bad',version:0,slots:[]}]},native,database:prisma(db),authenticate,handlers:{},loaders:{task:async()=>[]}}),/invalid mutation descriptor/);
 assert.throws(()=>createBackend({config:base,native,database:prisma(db),authenticate,handlers:{},loaders:{task:async()=>[]}}),/Missing handler edit for edit v1/);
 assert.throws(()=>createBackend({config:base,native,database:prisma(db),authenticate,handlers:{edit:async()=>{}},loaders:{}}),/Missing loader Task/);
});
test('Prisma persistence supports reusable bind without owning a transaction',async()=>{
 const reusable=new PrismaPersistence();let calls=0;
 const tx={$queryRawUnsafe:async()=>[{head:4}],$executeRawUnsafe:async()=>{calls++;return 1}};
 assert.equal(await reusable.bind(tx).call({op:'head',channel:'x'}),4);
 await reusable.bind(tx).call({op:'saveReceipt',clientId:'c',owner:'o',sequence:1,hash:'h',receipt:'r'});
 assert.equal(calls,1);
});
test('push commits business + compacted publication + exact durable receipt together',async()=>{
 const request=push('dedup',1,[mutation(1,'first')]);const receipt=await backend.push('alice',request);assert.deepEqual(JSON.parse(receipt),{requiredCheckpoints:[{scope:'shared',syncId:1}],requiredScope:'shared',requiredSyncId:1,rejections:[]});const calls=called;
 assert.equal(await backend.push('alice',request),receipt);assert.equal(called,calls);
 await assert.rejects(()=>backend.push('alice',push('dedup',1,[mutation(1,'changed')])),/request_conflict/);
 await assert.rejects(()=>backend.push('bob',request),/owner_mismatch/);
 await assert.rejects(()=>backend.push('alice',push('dedup',3,[mutation(1,'gap')])),/gap/);
 const page=await pull();assert.deepEqual(page,{scope:'shared',fromCursor:0,toCursor:1,changes:[{syncId:1,model:'Task',identity:{id:'a'},state:{title:'first'}}]});assert.equal(prepared,1);
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
 assert.equal(await count('business_task'),3);assert.equal((await pull()).toCursor,head);assert.equal((await db.$queryRawUnsafe("SELECT * FROM otter_client WHERE client_id='crash'")).length,0);
});
test('unsupported versions abort before handlers, invalid bodies settle with empty checkpoints',async()=>{
 const before=called;await assert.rejects(()=>backend.push('alice',push('version',1,[mutation(1,'ignored','v'),{...mutation(2,'bad','w'),version:2}])),/mutation_version_unsupported/);assert.equal(called,before);
 const result=JSON.parse(await backend.push('alice',push('invalid',1,[{ordinal:1,name:'absent',operations:[]}])));assert.deepEqual(result,{requiredCheckpoints:[],requiredScope:'',requiredSyncId:0,rejections:[{ordinal:1,code:'mutation.invalid'}]});
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
 await assert.rejects(()=>make('Not a machine code').push('alice',push('bad-translator',1,[mutation(1,'x')])),/stable machine code/);assert.equal((await db.$queryRawUnsafe("SELECT * FROM otter_client WHERE client_id='bad-translator'")).length,0);
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
 assert.equal((await db.$queryRawUnsafe("SELECT * FROM business_task WHERE id='caught'")).length,0);assert.equal((await db.$queryRawUnsafe("SELECT * FROM otter_client WHERE client_id='caught'")).length,0);
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
 assert.deepEqual(frames[1].changes.at(-1),{syncId:frames[1].toCursor,model:'Task',identity:{id:'live-external'},state:{title:'committed'}});

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
