import '../mutation/model_mutation.dart';
import '../mutation/mutation_store.dart';
import '../schema/model_id.dart';
import '../schema/model_schema.dart';
import '../schema/model_registry.dart';

/// A row's own queue entries plus the deletes it inherits from its ancestors.
///
/// The queue holds one entry per action, and a cascade delete is one action:
/// the row the user named is the only one in the queue, so a descendant's own
/// queue says nothing about the delete that took it. Replay closes that gap
/// here rather than by writing more queue rows — the schema already says what
/// falls with what, and deriving it means a rejection can put the ancestor
/// back without anything to unpick.
///
/// The synthesized delete borrows the ancestor entry's position, so it lands in
/// the row's history exactly where the action did: an edit the user made
/// afterwards still comes after it.
final class EffectiveMutations<I extends ModelId>
    implements SurvivingMutations<I> {
  const EffectiveMutations({
    required this.registry,
    required this.entry,
    required this.own,
  });

  final ModelRegistry registry;

  /// The row's own Model — the bottom of the walk.
  final ModelRegistryEntry entry;

  final MutationStore<I> own;

  @override
  Future<List<ModelMutation<I>>> read(I id) async {
    final mutations = <ModelMutation<I>>[...await own.read(id)];
    for (final position in await _inheritedPositions(entry, id)) {
      mutations.add(
        ModelMutation<I>(
          position: position,
          id: id,
          operation: MutationOperation.delete,
          values: const {},
          inherited: true,
        ),
      );
    }
    mutations.sort((left, right) => left.position.compareTo(right.position));
    return List.unmodifiable(mutations);
  }

  /// Walks up the `onTargetDelete: delete` references, collecting the position
  /// of every ancestor delete that still stands.
  Future<List<MutationPosition>> _inheritedPositions(
    ModelRegistryEntry child,
    ModelId childId,
  ) async {
    final positions = <MutationPosition>[];
    var current = child;
    var currentId = childId;
    while (true) {
      final relation = current.schema.relations
          .where((relation) => relation.deleteOnTarget)
          .firstOrNull;
      if (relation == null) return positions;

      final foreignKey = await _foreignKeyOf(current, currentId, relation);
      if (foreignKey == null) return positions;

      final parent = registry[relation.targetModel];
      if (parent == null) {
        throw StateError(
          'unknown Model "${relation.targetModel}" behind '
          '${current.schema.name}.${relation.name}',
        );
      }
      final parentId = parent.schema.createIdentity({
        for (var index = 0; index < relation.localFields.length; index += 1)
          relation.referencedFields[index]:
              foreignKey[relation.localFields[index]]!,
      });

      for (final mutation in await parent.pendingMutations(parentId)) {
        if (mutation.operation == MutationOperation.delete) {
          positions.add(mutation.position);
        }
      }
      current = parent;
      currentId = parentId;
    }
  }

  /// Whose child the row is, from wherever the device still says so.
  ///
  /// Truth first — once the row is deleted locally, main no longer holds it.
  /// Then main. Then, for a row that has neither, the row's own pending
  /// create: a row written offline inside a book that was then burned is gone
  /// from both tables and holds nothing aside, and its create is the only
  /// remaining record of the book it was written in.
  Future<Map<String, Object>?> _foreignKeyOf(
    ModelRegistryEntry entry,
    ModelId id,
    ModelRelationSchema relation,
  ) async {
    final record = await entry.readBefore(id) ?? await entry.readMain(id);
    final values =
        record?.fields ??
        (await entry.pendingMutations(id))
            .where((mutation) => mutation.operation == MutationOperation.create)
            .lastOrNull
            ?.values;
    if (values == null) return null;
    final foreignKey = <String, Object>{};
    for (final field in relation.localFields) {
      // A foreign key may be part of the row's identity, and identity
      // components are held apart from the rest of the record.
      final value = values[field] ?? id.components[field];
      if (value == null) return null;
      foreignKey[field] = value;
    }
    return foreignKey;
  }
}
