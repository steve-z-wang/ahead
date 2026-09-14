import 'dart:convert';
import 'dart:io';
import 'package:savoia/savoia.dart';
Future<void> main(List<String> args)async{
 final schema=jsonDecode(await File('../../fixtures/schemas/entry.json').readAsString()) as Map<String,dynamic>;
 final client=await Client.open(path:'${args[1]}/dart.sqlite',schema:schema,libraryPath:Platform.environment['SAVOIA_LIBRARY']!);
 final http=HttpClient();
 Future<String> transport(String kind,String body)async{final request=await http.postUrl(Uri.parse('${args[0]}/sync/${kind=='push'?'mutations':'pull'}'));request.headers.set('authorization','Bearer demo-user');request.headers.contentType=ContentType.json;request.write(body);final response=await request.close();final text=await utf8.decoder.bind(response).join();if(response.statusCode!=200)throw StateError('HTTP ${response.statusCode}: $text');return text;}
 try{
  await client.subscribe('book:demo');await client.sync(transport);
  final initial=await client.read('Entry',{'id':'entry-1'});if(initial?['text']!='resumed')throw StateError('Dart initial pull mismatch: $initial');
  final connection=await client.connect(transport);
  await client.mutate({'name':'Edit','operations':[{'model':'Entry','op':'update','identity':{'id':'entry-1'},'values':{'text':'  from Dart  '}}]});
  for(var i=0;i<200&&(await client.status())['pending']!=0;i++){await Future<void>.delayed(const Duration(milliseconds:10));}
  await connection.close();
  final row=await client.read('Entry',{'id':'entry-1'});final status=await client.status();if(row?['text']!='from Dart'||status['pending']!=0)throw StateError('Dart settlement mismatch: $row $status');
  print('Dart -> Rust -> HTTP -> Rust -> Prisma -> SQLite: passed');
 }finally{await client.close();http.close(force:true);}
}
