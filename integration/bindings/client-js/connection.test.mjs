import test from 'node:test';import assert from 'node:assert/strict';import {startConnection} from '../../../packages/client-js/connection.mts';
test('wake arriving during idle decision cannot be lost',async()=>{
 let release;const gate=new Promise(r=>release=r);let calls=0;const connection=await startConnection(async event=>{if(event==='next'){if(++calls===1)await gate;return {type:'idle'};}},async()=>{},async()=> '');await connection.wake();release();await new Promise(r=>setTimeout(r,10));assert.ok(calls>=2);await connection.close();
});
test('close aborts an uncooperative network promise and prevents late completion',async()=>{
 const events=[];let entered;const begun=new Promise(r=>entered=r);const connection=await startConnection(async event=>{events.push(event);return {type:'sync'};},async request=>{entered();await request('push','body');},async()=>new Promise(()=>{}));await begun;await connection.close();await new Promise(r=>setImmediate(r));assert.ok(events.includes('stop'));assert.ok(!events.includes('success'));assert.ok(!events.includes('failure'));
});
