import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {createExample} from '../../examples/rust-round-trip/server.mts';
import {Client} from '../../packages/client-js/index.mts';

test('Node SDK -> native Rust -> HTTP -> Rust backend -> Prisma -> SQLite, then Dart',async()=>{
 const app=await createExample();const directory=await mkdtemp(join(tmpdir(),'otter-e2e-'));let client;let server;
 try{
  await app.initialize();server=await app.listen(0);const url=server.url;
  const transport=async(kind,body)=>{const response=await fetch(`${url}/sync/${kind==='push'?'mutations':'pull'}`,{method:'POST',headers:{authorization:'Bearer demo-user','content-type':'application/json'},body});if(!response.ok)throw Error(`HTTP ${response.status}: ${await response.text()}`);return response.text();};
  client=await Client.open({path:join(directory,'client.sqlite'),schema:app.schema});await client.subscribe('book:demo');await client.sync(transport);assert.equal((await client.read('Entry',{id:'entry-1'})).text,'Hello from the server');
  await client.mutate({name:'Edit',operations:[{model:'Entry',op:'update',identity:{id:'entry-1'},values:{text:'  offline edit  '}}]});
  assert.equal((await client.read('Entry',{id:'entry-1'})).text,'  offline edit  ');const frozen=await client.freeze();await client.close();
  client=await Client.open({path:join(directory,'client.sqlite'),schema:app.schema});assert.equal(await client.freeze(),frozen);
  let dropped=false;await assert.rejects(()=>client.sync(async(kind,body)=>{const result=await transport(kind,body);if(kind==='push'&&!dropped){dropped=true;throw Error('lost ACK after COMMIT');}return result;}),/lost ACK/);
  const calls=app.handlerCalls;assert.equal((await client.status()).pending,1);await client.sync(transport);assert.equal(app.handlerCalls,calls);assert.equal((await client.read('Entry',{id:'entry-1'})).text,'offline edit');assert.equal((await client.status()).pending,0);assert.equal((await client.status()).beforeImages,0);
  await client.mutate({name:'Edit',operations:[{model:'Entry',op:'update',identity:{id:'entry-1'},values:{text:'reject'}}]});await client.sync(transport);assert.equal((await client.read('Entry',{id:'entry-1'})).text,'offline edit');assert.equal((await client.status()).rejections[0].code,'entry.denied');
  const gate=Promise.withResolvers();const entered=Promise.withResolvers();let held=false;
  await client.mutate({name:'Edit',operations:[{model:'Entry',op:'update',identity:{id:'entry-1'},values:{text:'first'}}]});
  const syncing=client.sync(async(kind,body)=>{const result=await transport(kind,body);if(kind==='push'&&!held){held=true;entered.resolve();await gate.promise;}return result;});
  await entered.promise;
  try {await Promise.race([client.mutate({name:'Edit',operations:[{model:'Entry',op:'update',identity:{id:'entry-1'},values:{text:'offline edit'}}]}),new Promise((_,reject)=>setTimeout(()=>reject(Error('local writes blocked by network')),500))]);}
  finally {gate.resolve();await syncing;}
  assert.equal((await client.read('Entry',{id:'entry-1'})).text,'offline edit');
  const background=await client.connect(transport);
  const waitSettled=async()=>{for(let i=0;i<200;i++){if((await client.status()).pending===0)return;await new Promise(r=>setTimeout(r,10));}throw Error('background sync did not settle');};
  try{await client.mutate({name:'Edit',operations:[{model:'Entry',op:'update',identity:{id:'entry-1'},values:{text:'  background  '}}]});await waitSettled();assert.equal((await client.read('Entry',{id:'entry-1'})).text,'background');await background.pause();await client.mutate({name:'Edit',operations:[{model:'Entry',op:'update',identity:{id:'entry-1'},values:{text:'  resumed  '}}]});await new Promise(r=>setTimeout(r,30));assert.equal((await client.status()).pending,1);await background.resume();await waitSettled();assert.equal((await client.read('Entry',{id:'entry-1'})).text,'resumed');}finally{await background.close();}
  const root=fileURLToPath(new URL('../..',import.meta.url));
  await new Promise((resolve,reject)=>{const child=spawn('dart',[`--packages=${join(root,'packages/dart/.dart_tool/package_config.json')}`,'../../integration/e2e/dart_client.dart',url,directory],{cwd:join(root,'packages/dart'),env:{...process.env,OTTER_LIBRARY:process.env.OTTER_LIBRARY ?? join(root,`target/debug/libotter_dart.${process.platform === 'darwin' ? 'dylib' : 'so'}`)},stdio:'inherit'});child.on('error',reject);child.on('exit',code=>code===0?resolve():reject(Error(`Dart E2E exited ${code}`)));});
  assert.equal((await app.db.entry.findUnique({where:{id:'entry-1'}})).text,'from Dart');
 }finally{await client?.close();await server?.close();await app.close();await rm(directory,{recursive:true,force:true});}
});
