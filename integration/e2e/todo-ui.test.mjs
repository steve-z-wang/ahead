import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import ts from 'typescript';

// Execute the actual hook with a deterministic React lifecycle and independently
// delivered model watches. No simulator or timing assumptions are needed here.
function hookHarness() {
  const state=[],effects=[],cleanups=[];let user=null,todosListener,userListener;
  let todosDisposed=false,userDisposed=false,closed=false;
  const react={
    useRef:value=>({current:value}),useCallback:fn=>fn,
    useState:value=>{const index=state.length;state.push(value);return [value,next=>state[index]=next];},
    useEffect:effect=>effects.push(effect),
  };
  const session={
    session:{watch:listener=>{todosListener=listener;return ()=>{todosDisposed=true;};},close:async()=>{closed=true;}},
    client:{models:{user:{watch:(_options,listener)=>{userListener=listener;return ()=>{userDisposed=true;};}}}},
    user:async()=>user,rejections:async()=>[],dismiss:async()=>{},
  };
  const source=readFileSync(new URL('../../examples/todo/mobile/src/useTodos.ts',import.meta.url),'utf8');
  const code=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  const exports={};
  new Function('require','exports',code)(name=>{
    if(name==='react')return react;
    if(name==='./todo')return {openTodoSession:async()=>session,describeRejection:code=>code};
    throw Error(`Unexpected runtime dependency: ${name}`);
  },exports);
  exports.useTodos({user:'alice',url:'http://example.test'});
  for(const effect of effects)cleanups.push(effect());
  return {state,
    todos:rows=>todosListener(rows),
    user:row=>{user=row;userListener?.(row?[row]:[]);},
    close:()=>cleanups.forEach(cleanup=>cleanup()),
    disposed:()=>({todosDisposed,userDisposed,closed}),
  };
}
const tick=()=>new Promise(resolve=>setImmediate(resolve));
test('User-only delivery makes the Todo screen ready after a separate Todo page',async()=>{
  const hook=hookHarness();await tick();
  hook.todos(Array.from({length:50},(_,i)=>({id:String(i),title:'task',done:false,createdById:'alice'})));
  await tick();assert.equal(hook.state[0],'loading');
  hook.user({id:'alice',name:'Alice'});await tick();
  assert.equal(hook.state[0],'ready','User delivery must update readiness without another Todo change');
  assert.equal(hook.state[1].name,'Alice');assert.equal(hook.state[2].length,50);
  hook.user({id:'alice',name:'Updated Alice'});await tick();assert.equal(hook.state[1].name,'Updated Alice');
  hook.close();await tick();assert.deepEqual(hook.disposed(),{todosDisposed:true,userDisposed:true,closed:true});
});
