// Internal wire fixture for ACK-loss/transaction tests. Applications use Client.connect(server).
export async function syncProtocol(client, transport) {
 const completed=new Set();
 for (;;) {
  const frozen=await client.freeze();
  if(frozen!==null) {
   await client.acknowledge(JSON.parse(frozen).batchSequence,JSON.parse(await transport('push',frozen)));
   completed.clear();
   continue;
  }
  const status=await client.status();const scope=status.channels.find(scope=>!completed.has(scope));
  if(scope===undefined)return;
  const body=JSON.stringify({clientId:client.clientId,scope,fromCursor:status.cursors[scope]??0});
  const page=JSON.parse(await transport('pull',body));await client.applyPull(page);
  if(page.changes.length<50)completed.add(scope);
 }
}
