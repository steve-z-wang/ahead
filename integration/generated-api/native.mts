import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {Client} from '../../packages/client-js/index.mts';
import {schema,GeneratedClient} from './generated.ts';
const directory=await mkdtemp(join(tmpdir(),'generated-native-'));
const client=await Client.open({path:join(directory,'state.sqlite'),schema,owner:'test'});
try {
 const api=new GeneratedClient(client);
 const id='123e4567-e89b-42d3-a456-426614174000';
 await api.createEntry({entry:{id,title:'native',note:'before',at:new Date('2026-01-01T00:00:00Z'),tags:[],status:'active'}});
 await api.editEntry({entry:{identity:{id},values:{note:null}}});
 const row=await api.readEntry({id});
 if(row?.note!==null||row.title!=='native'||!(row.at instanceof Date))throw Error('native roundtrip');
 if((await api.entry()).length!==1)throw Error('native query');
 const filtered=await api.queryEntry({where:{at:new Date('2026-01-01T01:00:00+01:00'),note:null},orderBy:[{field:'title',direction:'descending'}],limit:1});
 if(filtered.length!==1)throw Error('typed query normalization');
 await api.addBook({book:{id:'b',title:'Book'}});await api.addComment({comment:{id:'c',bookId:'b',text:'Comment'}});
 if((await api.commentBook({id:'c'}))?.id!=='b')throw Error('forward relation');
 if((await api.bookComments({id:'b'})).length!==1)throw Error('inverse relation');
 if(await client.freeze()===null)throw Error('native freeze');
}finally{await client.close();await rm(directory,{recursive:true,force:true})}
