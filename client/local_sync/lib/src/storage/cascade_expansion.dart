import '../schema/model_id.dart';
import '../schema/relation_index.dart';
import '../schema/model_registry.dart';
import 'local_value_codec.dart';

/// Which of a Model's two tables the walk reads.
///
/// The flows differ: a local delete and a downlink absence must account for
/// everything the device holds ([mainAndBefore]), while a rejection rebuilds
/// from what was held aside ([before]).
enum CascadeScanSource { main, before, mainAndBefore }

/// Expands one row into everything the schema says falls with it.
///
/// The expansion is derived, never stored: given a row, it follows the
/// declared `onTargetDelete: delete` references down through the local tables
/// returns the rows found, children first — the order a delete has to apply
/// them in, and the order a rebuild can safely walk backwards from.
final class CascadeExpansion {
  const CascadeExpansion(this.index, {this.codec = const LocalValueCodec()});

  final RelationIndex index;
  final LocalValueCodec codec;

  /// Every local row that falls with `(entry, id)`, deepest first.
  ///
  /// The parent itself is not included: what happens to it differs by flow —
  /// it alone carries the queue entry.
  Future<List<(ModelRegistryEntry, ModelId)>> descendantsOf(
    ModelRegistryEntry entry,
    ModelId id, {
    required CascadeScanSource sources,
  }) async {
    final found = <(ModelRegistryEntry, ModelId)>[];
    final seen = <String>{};
    await _walk(entry, id, sources, found, seen);
    return List.unmodifiable(found);
  }

  Future<void> _walk(
    ModelRegistryEntry entry,
    ModelId id,
    CascadeScanSource sources,
    List<(ModelRegistryEntry, ModelId)> found,
    Set<String> seen,
  ) async {
    for (final incoming in index.incoming(entry.schema.name)) {
      if (!incoming.relation.deleteOnTarget) continue;
      for (final childId in await _children(incoming, id, sources)) {
        // Keyed by the encoded identity, never by the id object: a generated
        // ModelId has no toString of its own, so two rows of the same Model
        // would look identical here and the second would be skipped.
        final key =
            '${incoming.source.schema.name} '
            '${codec.encodeIdentity(incoming.source.schema, childId)}';
        if (!seen.add(key)) continue;
        await _walk(incoming.source, childId, sources, found, seen);
        found.add((incoming.source, childId));
      }
    }
  }

  Future<List<ModelId>> _children(
    IncomingRelation incoming,
    ModelId parentId,
    CascadeScanSource sources,
  ) async {
    final relation = incoming.relation;
    // A relation may only reference its target's identity (the compiler
    // enforces it), so the parent's own identity carries every value the
    // foreign key has to match.
    final foreignKey = <String, Object?>{
      for (var index = 0; index < relation.localFields.length; index += 1)
        relation.localFields[index]:
            parentId.components[relation.referencedFields[index]],
    };
    return switch (sources) {
      CascadeScanSource.main => incoming.source.identitiesInMain(foreignKey),
      CascadeScanSource.before => incoming.source.identitiesInBefore(
        foreignKey,
      ),
      CascadeScanSource.mainAndBefore => [
        ...await incoming.source.identitiesInMain(foreignKey),
        ...await incoming.source.identitiesInBefore(foreignKey),
      ],
    };
  }
}
