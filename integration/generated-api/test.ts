import {CreateEntry,EditEntry,RemoveEntries,decodeEntry,encodeEntry,GeneratedClient,type Entry} from './generated.ts';
const row:Entry={id:'123e4567-e89b-42d3-a456-426614174000',title:'hello',note:null,at:new Date('2026-01-01T00:00:00Z'),tags:['x'],status:'active'};
function check(v:unknown,m:string){if(!v)throw Error(m)}
const create=CreateEntry({entry:row});
check(!('id' in (create.operations[0] as {values:object}).values),'identity leaked into state');
check(JSON.stringify(decodeEntry(encodeEntry(row)))===JSON.stringify(row),'source conversion');
const patch=EditEntry({entry:{identity:{id:row.id},values:{note:null}}});
check(JSON.stringify((patch.operations[0] as {values:object}).values)==='{"note":null}','presence semantics');
check(RemoveEntries({entries:[]}).operations.length===0,'optional/list');
if(false){
 const api=new GeneratedClient({async read(){return null},async query(){return []},async mutate(){return 1}});
 // @ts-expect-error lists cannot be query predicates
 api.queryEntry({where:{tags:[]}});
 // @ts-expect-error enum ordering is not defined
 api.queryEntry({orderBy:[{field:'status',direction:'ascending'}]});
 // @ts-expect-error date filter must be a Date
 api.queryEntry({where:{at:'2026-01-01'}});

 // @ts-expect-error identity is immutable in patch
 EditEntry({entry:{identity:{id:row.id},values:{id:'bad'}}});
 // @ts-expect-error mutation forbids tags
 EditEntry({entry:{identity:{id:row.id},values:{tags:[]}}});
 // @ts-expect-error nonnullable title
 EditEntry({entry:{identity:{id:row.id},values:{title:null}}});
 // @ts-expect-error enum typo
 const bad:Entry={...row,status:'typo'};
}
const client=new GeneratedClient({async read(){return encodeEntry(row)},async query(){return [encodeEntry(row)]},async mutate(m){check(JSON.stringify(m)===JSON.stringify(create),'forwarding');return 1}});
async function main(){check((await client.readEntry({id:row.id}))?.at instanceof Date,'read decode');check((await client.entry()).length===1,'query facade');check(await client.createEntry({entry:row})===1,'mutate facade');}
main();
