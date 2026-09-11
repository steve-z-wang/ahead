import 'reflect-metadata';
import test from 'node:test';
import assert from 'node:assert/strict';
import {Injectable,Module,Inject,Scope} from '@nestjs/common';
import {NestFactory} from '@nestjs/core';
import {Handles,Loads,LocalFirstModule,LOCAL_FIRST_BACKEND,type NestHandler,type NestLoader} from '../../packages/nest/index.ts';
import type {Handler} from '../../packages/server/index.mts';

type Tx={seen:string[]};type EditInput={task:{identity:{id:string};patch:{title:string}}};
const config={schema:{enums:[],models:[{name:'Task',identity:['id'],fields:[{name:'id',type:{kind:'scalar',name:'string'},nullable:false},{name:'title',type:{kind:'scalar',name:'string'},nullable:false}]}]},mutations:[{name:'edit',version:1,slots:[]}]};
const native={validateConfig:()=>{},processPush:async(_c:string,owner:string,_p:string,_r:string,callback:(r:string)=>Promise<string>)=>callback(JSON.stringify({op:'handle',name:'edit',version:1,owner,arguments:{task:{identity:{id:'a'},patch:{title:'hello'}}}})),processPull:async()=>'',publish:async()=>'',negotiateLive:async()=>'',pullLive:async()=>''};
@Injectable()
class Business {
 private readonly prefix='saved:';
 @Handles('edit',1) async edit(context:Parameters<NestHandler<Tx,EditInput>>[0],input:EditInput){context.transaction.seen.push(this.prefix+input.task.patch.title);}
 @Loads('Task') async load(_context:Parameters<NestLoader<Tx>>[0],identities:readonly {id:string}[]){return identities.map(identity=>({id:identity.id,title:'loaded'}));}
}
const tx:Tx={seen:[]};
@Module({imports:[LocalFirstModule.register({config,native,transaction:async body=>body(tx),persistence:()=>({call:async()=>null}),principalChannel:x=>x,authorize:async()=>true})],providers:[Business]}) class App {}

test('Nest application context discovers and binds decorated provider methods',async()=>{
 const app=await NestFactory.createApplicationContext(App,{logger:false,abortOnError:false});
 try{const backend=app.get<any>(LOCAL_FIRST_BACKEND);await backend.push('alice','{}');assert.deepEqual(tx.seen,['saved:hello']);}
 finally{await app.close();}
});

test('duplicate decorators fail application startup',async()=>{
 @Injectable() class Duplicate {@Handles('edit',1) async edit() {}}
 @Module({imports:[LocalFirstModule.register({config,native,transaction:async body=>body(tx),persistence:()=>({call:async()=>null}),principalChannel:x=>x,authorize:async()=>true})],providers:[Business,Duplicate]}) class DuplicateApp {}
 await assert.rejects(()=>NestFactory.createApplicationContext(DuplicateApp,{logger:false,abortOnError:false}),/Duplicate handler edit v1/);
});

test('duplicate model loaders fail application startup',async()=>{
 @Injectable() class DuplicateLoader {@Loads('Task') async load(){return [];}}
 @Module({imports:[LocalFirstModule.register({config,native,transaction:async body=>body(tx),persistence:()=>({call:async()=>null}),principalChannel:x=>x,authorize:async()=>true})],providers:[Business,DuplicateLoader]}) class DuplicateLoaderApp {}
 await assert.rejects(()=>NestFactory.createApplicationContext(DuplicateLoaderApp,{logger:false,abortOnError:false}),/Duplicate loader Task/);
});

const structural:Handler<Tx,EditInput>=async(_context,input)=>{input.task.patch.title.toUpperCase();};
void structural;

test('decorators bind fully initialized providers with async dependencies',async()=>{
 let release!:(value:string)=>void;const gate=new Promise<string>(resolve=>{release=resolve;});const token=Symbol('async dependency');const state:Tx={seen:[]};
 @Injectable() class DelayedBusiness{
  #prefix:string;constructor(@Inject(token) prefix:string){this.#prefix=prefix;}
  @Handles('edit',1)async edit(ctx:{transaction:Tx}){ctx.transaction.seen.push(this.#prefix);}
  @Loads('Task')async load(){return [];}
 }
 @Module({imports:[LocalFirstModule.register({config,native,transaction:async body=>body(state),persistence:()=>({call:async()=>null}),principalChannel:x=>x,authorize:async()=>true})],providers:[{provide:token,useFactory:()=>gate},DelayedBusiness]})class DelayedApp{}
 const opening=NestFactory.createApplicationContext(DelayedApp,{logger:false,abortOnError:false});await new Promise(resolve=>setTimeout(resolve,10));release('initialized');const app=await opening;
 try{await app.get<any>(LOCAL_FIRST_BACKEND).push('u','{}');assert.deepEqual(state.seen,['initialized']);}finally{await app.close();}
});
test('request-scoped decorated providers fail startup explicitly',async()=>{
 @Injectable({scope:Scope.REQUEST})class PerRequest{@Handles('edit',1)async edit(){}@Loads('Task')async load(){return [];}}
 @Module({imports:[LocalFirstModule.register({config,native,transaction:async body=>body(tx),persistence:()=>({call:async()=>null}),principalChannel:x=>x,authorize:async()=>true})],providers:[PerRequest]})class ScopedApp{}
 await assert.rejects(()=>NestFactory.createApplicationContext(ScopedApp,{logger:false,abortOnError:false}),/singleton/);
});
