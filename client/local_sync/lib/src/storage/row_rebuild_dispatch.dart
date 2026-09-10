import '../mutation/model_mutation.dart';
import '../mutation/mutation_store.dart';
import '../schema/model_id.dart';
import '../schema/model_registry.dart';
import 'cascade_expansion.dart';
import 'local_value_codec.dart';

/// Visits every row the given queue rows touch, once each.
///
/// Both flows that disturb the queue name their rows the same way — through
/// the mutations that left it — but they mean opposite things by it, so the
/// caller supplies which: [ModelRegistryEntry.rebuild] to undo a rejected
/// edit, [ModelRegistryEntry.settle] to accept one.
Future<void> visitQueuedRows(
  ModelRegistry registry,
  Iterable<StoredMutationOperation> rows,
  Future<void> Function(ModelRegistryEntry entry, ModelId id) visit, {
  LocalValueCodec codec = const LocalValueCodec(),
}) async {
  final seen = <String>{};
  for (final row in rows) {
    if (!seen.add('${row.model} ${row.identityJson}')) continue;
    final entry = registry[row.model];
    if (entry == null) {
      throw StateError('unknown Model "${row.model}" in the Uplink queue');
    }
    await visit(entry, codec.decodeIdentity(entry.schema, row.identityJson));
  }
}

/// Visits the rows that fell with each of the given queue rows that was a
/// delete.
///
/// A cascade delete leaves one entry in the queue, so a settlement that reads
/// only the queue sees only the row the user named. The rest are derived the
/// same way they were deleted — by walking the schema — this time over the
/// truth held aside, which is where a deleted row is all that is left of it.
Future<void> visitFallenRows(
  ModelRegistry registry,
  CascadeExpansion expansion,
  Iterable<StoredMutationOperation> rows,
  Future<void> Function(ModelRegistryEntry entry, ModelId id) visit, {
  LocalValueCodec codec = const LocalValueCodec(),
}) => visitQueuedRows(registry, rows.where(_isDelete), (entry, id) async {
  final fallen = await expansion.descendantsOf(
    entry,
    id,
    sources: CascadeScanSource.before,
  );
  for (final (descendant, descendantId) in fallen) {
    await visit(descendant, descendantId);
  }
}, codec: codec);

bool _isDelete(StoredMutationOperation row) =>
    row.operation == MutationOperation.delete.name;
