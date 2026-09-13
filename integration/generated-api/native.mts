import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {GeneratedClient} from './client.ts';
const directory=await mkdtemp(join(tmpdir(),'generated-native-'));
const client=await GeneratedClient.open({path:join(directory,'state.sqlite')});
try {
 const id='123e4567-e89b-42d3-a456-426614174000';
 await client.transaction(async tx=>{
  await tx.mutate.createEntry({entry:{id,title:'native',note:'before',at:new Date('2026-01-01T00:00:00Z'),tags:[],status:'active'}});
  await tx.mutate.editEntry({entry:{identity:{id},values:{note:null}}});
  const inside=await tx.models.entry.get({id});
  if(inside?.note!==null)throw Error('read your writes');
 });
 const row=await client.models.entry.get({id});
 if(row?.note!==null||row.title!=='native'||!(row.at instanceof Date))throw Error('native roundtrip');
 if((await client.models.entry.query()).length!==1)throw Error('native query');
 const filtered=await client.models.entry.query({where:{at:new Date('2026-01-01T01:00:00+01:00'),note:null},orderBy:[{field:'title',direction:'descending'}],limit:1});
 if(filtered.length!==1)throw Error('typed query normalization');
 await client.transaction(async tx=>{await tx.mutate.addBook({book:{id:'b',title:'Book'}});await tx.mutate.addComment({comment:{id:'c',bookId:'b',text:'Comment'}});});
 if((await client.models.comment.book({id:'c'}))?.id!=='b')throw Error('forward relation');
 if((await client.models.book.comments({id:'b'})).length!==1)throw Error('inverse relation');
 await client.transaction(async tx=>{await tx.models.book.create({id:'local',title:'Local only'});await tx.models.book.update({id:'local'},{title:'Local edited'});});
 if((await client.models.book.get({id:'local'}))?.title!=='Local edited')throw Error('local write');
 const seen:number[]=[];const stop=client.models.book.watch({},rows=>seen.push(rows.length));
 await client.transaction(tx=>tx.models.book.delete({id:'local'}));
 await new Promise(r=>setTimeout(r,20));stop();
 if(seen[0]!==2||seen[seen.length-1]!==1)throw Error(`watch ${seen}`);
 if(await client.client.freeze()===null)throw Error('native freeze');
}finally{await client.close();await rm(directory,{recursive:true,force:true})}
