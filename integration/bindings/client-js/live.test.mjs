import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { WebSocketServer } from '../../../packages/server/node_modules/ws/wrapper.mjs';
import * as runtime from '../../../packages/client-js/index.mts';

const timeout = (p) => Promise.race([p, new Promise((_, reject) => { const t = setTimeout(() => reject(Error('timeout')), 3000); t.unref(); })]);

test('live transport sends saved cursors and serializes pages, cancellation ends the socket', async () => {
  assert.equal(typeof runtime.websocketTransport, 'function');
  const server = new WebSocketServer({port:0});
  await once(server,'listening');
  const abort = new AbortController();
  const frames = [];
  const connected = once(server,'connection');
  const live = runtime.websocketTransport({url:`http://127.0.0.1:${server.address().port}`,token:'secret'});
  const running = live.stream({scopes:['scope'],cursors:{scope:12}}, async page => { frames.push(page); }, abort.signal);
  try {
    const [socket, request] = await timeout(connected);
    assert.equal(request.headers.authorization,'Bearer secret');
    const [message] = await timeout(once(socket,'message'));
    assert.deepEqual(JSON.parse(message),{type:'subscribe',scopes:['scope'],cursors:{scope:12}});
    const closed = once(socket,'close');
    socket.send(JSON.stringify({type:'subscribed',scopes:['scope'],rejections:[]}));
    socket.send(JSON.stringify({scope:'scope',fromCursor:12,toCursor:13,changes:[]}));
    await timeout(new Promise(resolve => { const check = () => frames.length ? resolve() : setImmediate(check); check(); }));
    assert.equal(frames[0].toCursor,13);
    abort.abort();
    await timeout(running);
    await timeout(closed);
  } finally { abort.abort(); for (const s of server.clients) s.terminate(); await new Promise(r => server.close(r)); }
});

test('live transport cancellation does not wait for a stalled token', async () => {
  assert.equal(typeof runtime.websocketTransport, 'function');
  const abort = new AbortController();
  const live = runtime.websocketTransport({url:'http://127.0.0.1:1',token:()=>new Promise(()=>{})});
  const running = live.stream({scopes:['scope'],cursors:{scope:0}},async()=>{},abort.signal);
  abort.abort();
  await timeout(running);
});

test('invalid WebSocket credentials reject the session rather than leaking a rejected task', async () => {
 const live = runtime.websocketTransport({url:'http://127.0.0.1:1',token:'invalid\nheader'});
 await assert.rejects(timeout(live.stream({scopes:['scope'],cursors:{scope:0}},async()=>{},new AbortController().signal)), /header|character/i);
});

import { createServer } from 'node:http';
import { mkdtemp, rm, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
async function openClient() {
 const dir = await mkdtemp(join(tmpdir(),'ahead-live-'));
 const schema = JSON.parse(await readFile(new URL('../../../fixtures/schemas/entry.json',import.meta.url),'utf8'));
 const client = await runtime.Client.open({path:join(dir,'client.sqlite'),schema});
 return {client, async close() { await client.close(); await rm(dir,{recursive:true,force:true}); }};
}
const page = (text, cursor=0) => ({scope:'scope',fromCursor:cursor,toCursor:cursor+1,changes:[{syncId:cursor+1,model:'Entry',identity:{id:'live'},stamp:cursor+1,state:{text,note:null}}]});
async function until(predicate) {
 const deadline=Date.now()+5000;
 while(Date.now()<deadline) { if(await predicate()) return; await new Promise(r=>setTimeout(r,5)); }
 throw Error('condition timed out');
}

test('client replaces subscriptions from saved cursors and guards queued obsolete pages', async()=>{
 const fixture=await openClient(); const {client}=fixture; const errors=[];
 const server=new WebSocketServer({port:0}); await once(server,'listening');
 const sockets=[]; const handshakes=[];
 server.on('connection',s=>{sockets.push(s);s.on('message',m=>{const sub=JSON.parse(m);handshakes.push(sub);s.send(JSON.stringify({type:'subscribed',scopes:sub.scopes,rejections:[]}));});});
 try {
  const live=runtime.websocketTransport({url:`http://127.0.0.1:${server.address().port}`,token:'secret'});
  const connection=await client.connectLive(live,{onError:e=>errors.push(e)});
  await client.subscribe('scope'); await until(()=>handshakes.length===1);
  sockets[0].send(JSON.stringify(page('first')));
  await until(async()=>(await client.read('Entry',{id:'live'}))?.text==='first');
  const gate=Promise.withResolvers(),entered=Promise.withResolvers();
  const tx=client.transaction(async()=>{entered.resolve();await gate.promise;});await entered.promise;
  sockets[0].send(JSON.stringify(page('stale',1)));
  const removed=client.unsubscribe('scope');const restored=client.subscribe('scope');
  gate.resolve();await tx;await removed;await restored;
  await until(()=>handshakes.length>=2);
  assert.equal(await client.read('Entry',{id:'live'}), null);
  const latest=handshakes.at(-1);assert.equal(latest.cursors.scope,0);
  sockets.at(-1).send(JSON.stringify(page('fresh',0)));
  await until(async()=>(await client.read('Entry',{id:'live'}))?.text==='fresh');
  await connection.pause();await until(()=>server.clients.size===0);
  await connection.resume();await until(()=>handshakes.length>=3);
  assert.equal(handshakes.at(-1).cursors.scope,1);
  assert.equal(errors.length,0);
  sockets.at(-1).send(JSON.stringify(page('gap',10)));await until(()=>errors.length>0);assert.match(String(errors[0]),/pull cursor gap/);
  await connection.close();await until(()=>server.clients.size===0);
 } finally { await fixture.close(); for(const s of server.clients)s.terminate();await new Promise(r=>server.close(r)); }
});

test('client retries upgrade authentication and survives failed refresh',async()=>{
 const fixture=await openClient();const {client}=fixture;const errors=[];
 const server=createServer();const ws=new WebSocketServer({noServer:true});
 let token='expired', refreshes=0, accepted=0;
 server.on('upgrade',(req,socket,head)=>{if(req.headers.authorization!=='Bearer valid'){socket.end('HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n');return;}ws.handleUpgrade(req,socket,head,s=>{accepted++;s.on('message',m=>s.send(JSON.stringify({type:'subscribed',scopes:JSON.parse(m).scopes,rejections:[]})));});});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 try {
  await client.subscribe('scope');
  await client.connectLive(runtime.websocketTransport({url:`http://127.0.0.1:${server.address().port}`,token:()=>token}),{onError:e=>errors.push(e),refreshAuth:async()=>{if(++refreshes===1)throw Error('refresh failed');token='valid';}});
  await until(()=>accepted===1);
  assert.equal(refreshes,2);assert.ok(errors.some(e=>e.message==='refresh failed'));
 } finally {await fixture.close();for(const s of ws.clients)s.terminate();await new Promise(r=>ws.close(r));await new Promise(r=>server.close(r));}
});

test('close cancels opening handshake and ignores its eventual server response',async()=>{
 const fixture=await openClient();const server=createServer();const entered=Promise.withResolvers();let pending;
 server.on('upgrade',(_req,socket)=>{pending=socket;socket.resume();socket.on('end',()=>socket.destroy());entered.resolve();});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 try {
  await fixture.client.subscribe('scope');
  const connection=await fixture.client.connectLive(runtime.websocketTransport({url:`http://127.0.0.1:${server.address().port}`,token:'secret'}));
  await timeout(entered.promise);const closed=once(pending,'close');
  await timeout(connection.close());await timeout(closed);
 }finally{await fixture.close();pending?.destroy();await new Promise(r=>server.close(r));}
});

test('client close abandons a stalled live token and never opens after it resolves',async()=>{
 const fixture=await openClient();let requests=0;const token=Promise.withResolvers();const called=Promise.withResolvers();
 const server=new WebSocketServer({port:0});await once(server,'listening');server.on('connection',()=>requests++);
 try {
  await fixture.client.subscribe('scope');
  await fixture.client.connectLive(runtime.websocketTransport({url:`http://127.0.0.1:${server.address().port}`,token:()=>{called.resolve();return token.promise;}}));
  await timeout(called.promise);await timeout(fixture.client.close());token.resolve('late');
  await new Promise(r=>setImmediate(r));assert.equal(requests,0);
 }finally{await fixture.close();for(const s of server.clients)s.terminate();await new Promise(r=>server.close(r));}
});
