import '../api/model_writer.dart';
import '../mutation/mutation_store.dart';
import '../schema/model_id.dart';
import 'before_image_store.dart';
import 'canonical_store.dart';

/// A direct outer-transaction edit, straight to the table and final at commit
/// (CAP-488/616).
///
/// Final cuts both ways. The row may be dirty — a pending act holds its truth
/// aside — and a final edit landing on it belongs BENEATH the provisional
/// edits, not among them: the held truth advances with the write, so a later
/// rejection rebuilds from a base that already contains it and a write nothing
/// refused is never undone.
///
/// A dirty row does not always HOLD truth, though. A row whose divergence
/// began with a queued create holds none — the queued create is itself the
/// marker that prior truth was nonexistence — and a final delete drops what
/// was held, so a create landing after one holds none either. A final edit in
/// either state has nothing to advance, so it establishes a base: the
/// post-write row becomes local truth, and refusing the pending act leaves
/// exactly what the caller committed rather than purging it. A final delete
/// needs no base, because nonexistence is what an absent twin already says.
///
/// Final means "nothing local will undo it", never "this value is now
/// permanent": the Backend remains free to speak for the row, and a settling
/// or later canonical Downlink value replaces what was written here.
final class DirectModelWriter<I extends ModelId> implements ModelWriter<I> {
  const DirectModelWriter(
    this.canonical, {
    required this.before,
    required this.mutations,
    this.cascadeDescendants,
  });

  final CanonicalStore<I> canonical;
  final BeforeImageStore<I> before;

  /// The row's queued operations — what says whether it is dirty, and by what.
  final MutationStore<I> mutations;

  /// Deletes everything the schema says falls with the row, finally, in the
  /// same unit of work.
  ///
  /// The Model decides what a delete MEANS; this lane decides only that it is
  /// not synchronized (CAP-488). Null only where the Model stands alone — the
  /// assembly that knows the graph (`ModelRuntime`, which requires the
  /// registry) always supplies it.
  final Future<void> Function(I id)? cascadeDescendants;

  @override
  Future<void> create(I id, Map<String, Object?> values) async {
    await canonical.create(id, values);
    // Main was empty with truth held: a pending delete. The final create is
    // the truth now, so a rejection of that delete restores this row.
    if (await before.exists(id)) {
      await before.updateTruth(id, values);
      return;
    }
    await _establishTruthUnderPendingAct(id);
  }

  @override
  Future<void> update(I id, Map<String, Object?> patch) async {
    if (patch.isEmpty) return;
    await canonical.update(id, patch);
    if (await before.exists(id)) {
      await before.patchTruth(id, patch);
      return;
    }
    await _establishTruthUnderPendingAct(id);
  }

  @override
  Future<void> delete(I id) async {
    // Children first, and inside the same unit of work: the user's one act
    // either happened completely or not at all.
    await cascadeDescendants?.call(id);
    await canonical.delete(id);
    // The final delete makes truth nonexistence; dropping the twin is how
    // nonexistence is held. A pending act's accepted CREATE can later replay
    // over this purged truth and stand a new row up — that is the one edge
    // where truth advances from nothing, and it is correct: the create was
    // accepted after the delete was final.
    await before.drop(id);
  }

  /// Records the row as it now stands as its own base truth.
  ///
  /// Only for a dirty row holding none: a clean row needs no base (holding one
  /// would break the sparsity that makes "has a before-image" mean "is
  /// dirty"), and a row already holding truth advanced it above.
  Future<void> _establishTruthUnderPendingAct(I id) async {
    if ((await mutations.read(id)).isEmpty) return;
    final row = await canonical.get(id);
    if (row == null) return;
    await before.updateTruth(id, {
      for (final entry in row.fields.entries)
        if (!before.schema.isIdentityField(entry.key)) entry.key: entry.value,
    });
  }
}
