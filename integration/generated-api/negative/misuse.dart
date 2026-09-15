// Generated Dart API misuse that must NOT analyze. verify.sh runs `dart analyze`
// on this directory alone and requires every error below to be reported; the
// TypeScript twin is the `@ts-expect-error` block in ../test.ts.
// ignore_for_file: unused_local_variable
import '../generated.dart';

void misuse(GeneratedClient client, GeneratedTransaction tx, Entry row) {
  // lists cannot be query predicates
  client.models.entry.query(where: const EntryFilter(tags: Present(['x'])));
  // enum ordering is not defined
  client.models.entry.query(orderBy: [EntryOrder(EntryOrderField.byStatus)]);
  // date filter must be a DateTime
  client.models.entry.query(where: const EntryFilter(at: Present('2026-01-01')));
  // watch is not available inside a transaction
  tx.models.entry.watch();
  // identity is immutable in patch
  tx.mutate.editEntry(entry: EditEntryEntryUpdate(identity: EntryIdentity(id: row.id), id: 'bad'));
  // mutation forbids tags
  tx.mutate.editEntry(entry: EditEntryEntryUpdate(identity: EntryIdentity(id: row.id), tags: const Present(['x'])));
  // nonnullable title
  tx.mutate.editEntry(entry: EditEntryEntryUpdate(identity: EntryIdentity(id: row.id), title: const Present(null)));
  // enum typo
  final Entry bad = Entry(id: row.id, title: row.title, note: row.note, at: row.at, tags: row.tags, status: Status.typo);
}
