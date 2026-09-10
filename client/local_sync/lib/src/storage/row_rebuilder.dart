import '../projection/model_record.dart';
import '../projection/mutation_reducer.dart';
import '../schema/model_id.dart';
import 'before_image_store.dart';
import 'canonical_store.dart';
import '../mutation/mutation_store.dart';

/// Rebuilds one row from truth plus the edits that still stand.
///
/// The single primitive behind both flows that disturb a dirty row (CAP-393
/// spec §4 and §5): a rejection drops a mutation from the queue, new truth
/// lands underneath, and either way the row is recomputed the same way —
/// start from the before-image (or from nonexistence, for a create origin),
/// replay what survives, write the result to main. When the queue empties the
/// before-image is dropped, because main then equals truth exactly.
///
/// Only ever called for a row known to be dirty — one whose mutation was just
/// settled or rejected, or which holds a before-image. A clean row has neither
/// input and rebuilding it would compute "delete me".
final class RowRebuilder<I extends ModelId> {
  const RowRebuilder({
    required this.main,
    required this.before,
    required this.mutations,
    required this.replay,
  });

  final CanonicalStore<I> main;
  final BeforeImageStore<I> before;

  /// What still stands for the row — its queue entries, and any delete it
  /// inherits from an ancestor the user deleted.
  final SurvivingMutations<I> mutations;
  final ProjectionReducer<I> replay;

  Future<void> rebuild(I id) async {
    final truth = await before.read(id);
    final surviving = await mutations.read(id);
    ModelRecord<I>? rebuilt;
    try {
      rebuilt = replay.reduce(truth, surviving);
    } on ProjectionIntegrityException {
      // The edits no longer apply to the truth beneath them — the server
      // deleted a row we were editing, or created one we were creating. Truth
      // wins: those mutations are doomed, and the rejection that is already
      // on its way rebuilds this row to the same answer.
      rebuilt = truth;
    }

    if (rebuilt == null) {
      await main.purge(id);
    } else {
      await main.upsert(id, _writable(rebuilt));
    }

    // A row with nothing pending has nothing to diverge from truth by, so the
    // twin must not keep holding it — sparsity is the invariant that makes
    // "has a before-image" mean "is dirty".
    if (surviving.isEmpty) await before.drop(id);
  }

  Map<String, Object?> _writable(ModelRecord<I> record) => {
    for (final entry in record.fields.entries)
      if (!before.schema.isIdentityField(entry.key)) entry.key: entry.value,
  };
}
