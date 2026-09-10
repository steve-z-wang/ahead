import '../schema/model_id.dart';
import '../schema/relation_index.dart';
import '../schema/model_registry.dart';
import '../storage/cascade_expansion.dart';

/// Applies a delete to everything the schema says falls with the deleted row.
///
/// A delete is one action, and the action's reach is the schema's, not the
/// caller's: deleting a book takes its pages, their photos and their replies
/// with it, here and now, offline, because the user's device is where the
/// action happened. What it deliberately does not do is write anything to the
/// queue — the wire carries the named row and nothing else, and the server
/// runs the same expansion over its own tables.
///
/// The graph is the SCHEMA's and is walked identically for both write paths
/// (CAP-488): a Model's `onTargetDelete: delete` says what deleting one of its
/// rows means, and `write` versus `mutate` says only whether the operation is
/// synchronized. What differs is how far back each descendant can be taken —
/// [deleteDescendants] leaves a provisional delete a rejection can undo,
/// [deleteDescendantsFinally] leaves one nothing will.
final class CascadeDeleter {
  CascadeDeleter(this.registry)
    : _expansion = CascadeExpansion(RelationIndex.of(registry));

  final ModelRegistry registry;
  final CascadeExpansion _expansion;

  /// Deletes every local row that falls with `(model, id)`, deepest first,
  /// PROVISIONALLY: each descendant's truth is held aside, so refusing the act
  /// the delete belongs to restores the whole subtree.
  ///
  /// The named row itself is left to its own writer: it alone carries the
  /// action's queue entry.
  Future<void> deleteDescendants(String model, ModelId id) => _visitDescendants(
    model,
    id,
    (entry, descendantId) => entry.deleteByCascade(descendantId),
  );

  /// The same graph, FINALLY: each descendant ends where a direct transaction
  /// delete ends — gone from main and holding no truth — because that delete is
  /// final at commit and its reach is the schema's.
  ///
  /// The named row itself is left to its own writer, exactly as above.
  Future<void> deleteDescendantsFinally(String model, ModelId id) =>
      _visitDescendants(
        model,
        id,
        (entry, descendantId) => entry.deleteFinallyByCascade(descendantId),
      );

  Future<void> _visitDescendants(
    String model,
    ModelId id,
    Future<void> Function(ModelRegistryEntry entry, ModelId id) visit,
  ) async {
    final entry = registry[model];
    if (entry == null) throw StateError('unknown Model "$model"');
    final descendants = await _expansion.descendantsOf(
      entry,
      id,
      // Both sides: a descendant the user already deleted has left main, and
      // it must still be accounted for so its truth is not orphaned.
      sources: CascadeScanSource.mainAndBefore,
    );
    for (final (descendant, descendantId) in descendants) {
      await visit(descendant, descendantId);
    }
  }
}
