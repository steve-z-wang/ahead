import '../schema/model_id.dart';
import '../storage/before_image_store.dart';
import '../storage/canonical_store.dart';
import 'model_mutation.dart';
import 'mutation_store.dart';

/// Writes an optimistic edit where the user will read it: into the main table
/// itself, with the row's prior truth copied aside first (CAP-393 spec §3).
///
/// Every write belongs to one named act and states whether the Backend
/// receives it: a returned slot is `wire: true`, a companion written inside
/// the act's callback is `wire: false` (CAP-488). Both ride the queue, because
/// both share the act's fate; only the first is encoded.
///
/// Copy-aside, the in-place edit and the queue row are one unit — `mutate`
/// applies the whole act in one transaction, so a failure part-way leaves
/// nothing behind and cannot break the sparsity that makes "holds a
/// before-image" mean "is dirty". Failures themselves are inherent rather than
/// checked — a double create collides with the primary key, an update or
/// delete of a row that is not there affects no rows, and the value codec
/// rejects a malformed scalar as it encodes the queue row.
final class ModelMutationWriter<I extends ModelId> {
  ModelMutationWriter(
    this.store, {
    required this.before,
    required this.main,
    this.cascadeDescendants,
  });

  final MutationStore<I> store;
  final BeforeImageStore<I> before;
  final CanonicalStore<I> main;

  /// Deletes everything that falls with the row, in the same unit of work.
  ///
  /// Null only where the Model stands alone — the assembly that knows the
  /// graph (`ModelRuntime`, which requires the registry) always supplies it.
  final Future<void> Function(I id)? cascadeDescendants;

  Future<void> create(
    I id,
    Map<String, Object?> values, {
    required int mutationOrdinal,
    required bool wire,
    String? slotName,
  }) async {
    // No copy-aside: the queue's create is itself the marker that prior truth
    // was nonexistence.
    await main.create(id, values);
    await store.append(
      id: id,
      operation: MutationOperation.create,
      values: values,
      mutationOrdinal: mutationOrdinal,
      wire: wire,
      slotName: slotName,
    );
  }

  Future<void> update(
    I id,
    Map<String, Object?> patch, {
    required int mutationOrdinal,
    required bool wire,
    String? slotName,
  }) async {
    if (patch.isEmpty) return;
    await _holdTruth(id);
    await main.update(id, patch);
    await store.append(
      id: id,
      operation: MutationOperation.update,
      values: patch,
      mutationOrdinal: mutationOrdinal,
      wire: wire,
      slotName: slotName,
    );
  }

  Future<void> delete(
    I id, {
    required int mutationOrdinal,
    required bool wire,
    String? slotName,
  }) async {
    // Children first, and inside the same unit of work: the user's one act
    // either happened completely or not at all.
    await cascadeDescendants?.call(id);
    await _holdTruth(id);
    await main.delete(id);
    await store.append(
      id: id,
      operation: MutationOperation.delete,
      values: const {},
      mutationOrdinal: mutationOrdinal,
      wire: wire,
      slotName: slotName,
    );
  }

  /// Copies the row aside on its first edit only.
  ///
  /// Any pending edit at all means the main row has already drifted from the
  /// server's, so copying now would record an optimistic state as truth. That
  /// covers the row whose divergence began with a create, which holds nothing
  /// aside by design — the create in the queue is the marker that prior truth
  /// was nonexistence.
  Future<void> _holdTruth(I id) async {
    if ((await store.read(id)).isNotEmpty) return;
    await before.copyAside(id);
  }
}
