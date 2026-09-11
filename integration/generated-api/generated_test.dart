import 'dart:io';
import 'package:test/test.dart';
import 'package:local_first_state/local_first_state.dart';
import 'generated.dart';
void main(){
 const id='123e4567-e89b-42d3-a456-426614174000';
 final row=Entry(id:id,title:'hello',note:null,at:DateTime.utc(2026),tags:['x'],status:Status.active);
 test('source conversion, patch absence and explicit null',(){
  expect(Entry.fromRecord(row.toRecord()).at,row.at);
  expect(const EntryPatch(note:Present(null)).toRecord(),{'note':null});
  expect(const EntryPatch().toRecord(),isEmpty);
  expect((createEntry(entry:row)['operations'] as List).single['values'].containsKey('id'),false);
  expect((removeEntries(entries:[])['operations'] as List),isEmpty);
 });
 test('generated mutations and query use real native client',()async{
  final temp=await Directory.systemTemp.createTemp('generated-api-');
  final client=await Client.open(path:'${temp.path}/state.sqlite',schema:schema,owner:'test',libraryPath:Platform.environment['LFS_DART_LIBRARY'] ?? '../../target/debug/liblfs_dart.dylib');
  try{
   final api=GeneratedClient(client);
   expect(await api.mutate(createEntry(entry:row)),1);
   expect((await api.readEntry(const EntryIdentity(id:id)))?.title,'hello');
   await api.mutate(editEntry(entry:const EditEntryEntryUpdate(identity:EntryIdentity(id:id),note:Present('changed'))));
   await api.mutate(editEntry(entry:const EditEntryEntryUpdate(identity:EntryIdentity(id:id),note:Present(null))));
   final loaded=(await api.entry()).single;
   expect(loaded.note,isNull);expect(loaded.title,'hello');expect(loaded.at,row.at);
   expect((await api.queryEntry(where:EntryFilter(at:Present(DateTime.parse('2026-01-01T01:00:00+01:00')),note:const Present(null)),orderBy:const [EntryOrder(EntryOrderField.byTitle,descending:true)],limit:1)).length,1);
   await api.mutate(addBook(book:const Book(id:'b',title:'Book')));
   await api.mutate(addComment(comment:const Comment(id:'c',bookId:'b',text:'Comment')));
   expect((await api.commentBook(const CommentIdentity(id:'c')))?.id,'b');
   expect((await api.bookComments(const BookIdentity(id:'b'))).length,1);
   expect(await client.freeze(),isNotNull);
  }finally{await client.close();await temp.delete(recursive:true);}
 });
}
