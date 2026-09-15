import test from 'node:test';
import assert from 'node:assert/strict';
import * as module from '../../../packages/client-react-native/live.mts';
test('React Native transport is available without Node ws',()=>assert.equal(typeof module?.createServerConnection,'function'));
const tick=()=>new Promise(r=>setImmediate(r));
{
  class Socket {
    static last;
    constructor(url,protocols,options){this.url=url;this.options=options;Socket.last=this;}
    send(data){this.sent=JSON.parse(data);}
    close(){this.closed=true;}
    page(page){this.onmessage?.({data:JSON.stringify(page)});}
  }
  test('native socket sends auth, acknowledges before catch-up and bounds overflow',async()=>{
    let release;
    const gate=new Promise(r=>release=r);
    let recoveries=0;
    const pages=[];
    const abort=new AbortController();
    const live=module.createServerConnection({url:'http://localhost:4242',token:'alice'},Socket);
    const stream=live.stream({scopes:['scope']},async p=>pages.push(p.n),abort.signal,async()=>{recoveries++;if(recoveries===1)await gate;});
    await tick(); const socket=Socket.last;
    assert.equal(socket.options.headers.authorization,'Bearer alice');
    socket.onopen();
    assert.deepEqual(socket.sent,{type:'subscribe',scopes:['scope']});
    assert.equal(recoveries,0);
    socket.page({type:'subscribed',scopes:['scope'],rejections:[]});
    await tick();
    for(let n=0;n<70;n++) socket.page({n});
    assert.deepEqual(pages,[]);
    release(); await tick();
    assert.equal(recoveries,2);
    assert.deepEqual(pages,[64,65,66,67,68,69]);
    abort.abort(); await stream; assert.equal(socket.closed,true);
    socket.page({n:999}); await tick(); assert.equal(pages.includes(999),false);
  });
  test('cancellation ends token wait and prevents late socket creation',async()=>{
    let resolveToken;
    const token=new Promise(r=>resolveToken=r);
    const abort=new AbortController();
    Socket.last=undefined;
    const live=module.createServerConnection({url:'http://localhost',token:()=>token},Socket);
    const stream=live.stream({scopes:['s']},async()=>{},abort.signal,async()=>{});
    await tick(); abort.abort(); await stream;
    resolveToken('alice'); await tick(); assert.equal(Socket.last,undefined);
  });
  test('malformed acknowledgement rejects and closes socket',async()=>{
    const live=module.createServerConnection({url:'http://localhost',token:'alice'},Socket);
    const stream=live.stream({scopes:['s']},async()=>{},new AbortController().signal,async()=>{});
    await tick(); Socket.last.page({type:'subscribed',scopes:['other'],rejections:[]});
    await assert.rejects(stream,/acknowledgement/); assert.equal(Socket.last.closed,true);
  });
}

test('a native send failure rejects the stream instead of escaping the event callback',async()=>{
  let socket;
  class ThrowingSocket {
    constructor(){socket=this;}
    send(){throw Error('socket send failed');}
    close(){this.closed=true;}
  }
  const live=module.createServerConnection({url:'http://localhost',token:'alice'},ThrowingSocket);
  const stream=live.stream({scopes:['s']},async()=>{},new AbortController().signal,async()=>{});
  await tick();
  assert.doesNotThrow(()=>socket.onopen());
  await assert.rejects(stream,/socket send failed/);
  assert.equal(socket.closed,true);
});
{
  class Socket {
    static last;
    constructor(url,protocols,options){this.url=url;this.options=options;Socket.last=this;}
    send(data){this.sent=JSON.parse(data);}
    close(){this.closed=true;}
    page(page){this.onmessage?.({data:JSON.stringify(page)});}
  }
  test('cancellation during catch-up ends the session and ignores pages the socket still delivers',async()=>{
    let release; const gate=new Promise(r=>release=r);
    const applied=[]; let catchUps=0;
    const abort=new AbortController();
    const live=module.createServerConnection({url:'http://localhost',token:'alice'},Socket);
    const stream=live.stream({scopes:['s']},async p=>applied.push(p.n),abort.signal,async()=>{catchUps++;await gate;});
    await tick(); const socket=Socket.last; socket.onopen();
    socket.page({type:'subscribed',scopes:['s'],rejections:[]}); await tick();
    assert.equal(catchUps,1);
    socket.page({n:1});
    abort.abort(); await stream;
    assert.equal(socket.closed,true);
    release(); await tick(); await tick();
    socket.page({n:2}); await tick();
    assert.deepEqual(applied,[],'pages buffered or delivered after cancellation are discarded');
  });
  test('a closed native socket rejects the session so the driver can retry from the durable cursor',async()=>{
    const live=module.createServerConnection({url:'http://localhost',token:'alice'},Socket);
    const stream=live.stream({scopes:['s']},async()=>{},new AbortController().signal,async()=>{});
    await tick(); const socket=Socket.last; socket.onopen();
    socket.page({type:'subscribed',scopes:['s'],rejections:[]}); await tick();
    socket.onclose({code:1006,reason:'network lost'});
    await assert.rejects(stream,/live disconnected: 1006 network lost/);
    assert.equal(socket.closed,true);
    const again=live.stream({scopes:['s']},async()=>{},new AbortController().signal,async()=>{});
    await tick(); assert.notEqual(Socket.last,socket,'a new session opens a new socket');
    Socket.last.onerror({message:'refused'});
    await assert.rejects(again,/refused/);
  });
}
