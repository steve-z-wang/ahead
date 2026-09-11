import test from 'node:test';import assert from 'node:assert/strict';import {mkdtemp,readFile,rm} from 'node:fs/promises';import {tmpdir} from 'node:os';import {join} from 'node:path';import {Client} from '../../../packages/client-js/index.mts';
test('prerequisite failure stays optimistic and explicit retry unlocks Rust push',async()=>{
 const directory=await mkdtemp(join(tmpdir(),'lfs-prerequisite-'));const schema=JSON.parse(await readFile(new URL('../../../fixtures/schemas/entry.json',import.meta.url),'utf8'));schema.prerequisites=[{name:'Upload',fields:[{name:'key',type:'String'}]}];schema.requirements=[{model:'Entry',field:'note',name:'Upload',arguments:{key:'self'}}];
 const client=await Client.open({path:join(directory,'db'),schema,owner:'u'});
 try{await client.transaction(tx=>tx.direct({model:'Entry',op:'create',identity:{id:'e'},values:{text:'A'}}));await client.mutate({name:'Edit',operations:[{model:'Entry',op:'update',identity:{id:'e'},values:{note:'asset'}}]});let calls=0;const handlers={Upload:async args=>{assert.equal(args.key,'asset');if(++calls===1)throw Error('offline');}};
 await client.runPrerequisites(handlers);assert.equal((await client.read('Entry',{id:'e'})).note,'asset');assert.equal(await client.freeze(),null);let [task]=await client.pendingTasks();assert.equal(task.state,'failed');await client.setReadiness(task.key,'pending');await client.runPrerequisites(handlers);assert.equal(calls,2);assert.notEqual(await client.freeze(),null);
 }finally{await client.close();await rm(directory,{recursive:true,force:true});}
});
