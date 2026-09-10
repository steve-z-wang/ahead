import '../schema/model_id.dart';

/// One letter of the write vocabulary, as a value (CAP-439).
///
/// Operations stay `{Model} × {create, update, delete}` — the closed,
/// mechanical replication vocabulary. What changes is that they are now
/// *values*: constructing one has no effect at all, so they can be built in
/// loops, conditionals, helpers, or tests with no framework running. Only
/// `mutate` applies them, and only as part of one named mutation.
///
/// Generated code declares one exact subtype per `(Model, op)` pair, which is
/// what lets a slot be typed: a photo create cannot be handed to a slot that
/// declared a page create.
sealed class ModelOperation {
  const ModelOperation({required this.model, required this.id});

  /// The Model this operation writes, by name.
  final String model;

  /// The row it writes. A create names an identity that does not exist yet;
  /// an update and a delete carry the identity of a row that was read.
  final ModelId id;
}

/// `Model.create(...)` — a row that does not exist yet, with its complete
/// non-identity state.
base class ModelCreateOperation extends ModelOperation {
  ModelCreateOperation({
    required super.model,
    required super.id,
    required Map<String, Object?> values,
  }) : values = Map.unmodifiable(values);

  final Map<String, Object?> values;
}

/// `row.update(...)` — only the fields it touches. A key held at null is the
/// clear; a key that is absent was not touched at all.
base class ModelUpdateOperation extends ModelOperation {
  ModelUpdateOperation({
    required super.model,
    required super.id,
    required Map<String, Object?> patch,
  }) : patch = Map.unmodifiable(patch);

  final Map<String, Object?> patch;
}

/// `row.delete()` — which row, and nothing else.
base class ModelDeleteOperation extends ModelOperation {
  const ModelDeleteOperation({required super.model, required super.id});
}

/// One declared act-level wire (spec 2026-08-16-slot-bindings): [operation]'s
/// [fields] must equal [parent]'s row identity, field by field in the
/// parent identity's order.
///
/// A fact, not a check: generated code states which rows point at which
/// act-mate, and the handwritten verifier consumes it inside `mutate()`'s
/// transaction — where the stored rows an update or delete stands on can
/// actually be read.
final class SlotBinding {
  SlotBinding({
    required this.operation,
    required Iterable<String> fields,
    required this.parent,
  }) : fields = List.unmodifiable(fields);

  final ModelOperation operation;
  final List<String> fields;
  final ModelOperation parent;
}

/// One returned wire operation and the declared slot that supplied it.
final class MutationSlotOperation {
  MutationSlotOperation({
    required this.slotName,
    required this.operation,
    Iterable<String>? allowedPatchFields,
  }) : allowedPatchFields = allowedPatchFields == null
           ? null
           : Set.unmodifiable(allowedPatchFields);

  final String slotName;
  final ModelOperation operation;

  /// The complete schema-declared key projection for an update slot.
  /// Null for create and delete slots.
  final Set<String>? allowedPatchFields;
}

/// The current side of one generated sequence selector, bound to a concrete
/// operation returned by the act being enqueued.
final class MutationSequenceCurrentPath {
  MutationSequenceCurrentPath({
    required this.source,
    required Iterable<String> relations,
  }) : relations = List.unmodifiable(relations);

  final ModelOperation source;
  final List<String> relations;
}

/// One explicit product-order selector. The predecessor side remains a schema
/// descriptor so enqueue can match earlier durable slot operations; the
/// current side is already bound to this call's concrete operations.
final class MutationSequenceSelector {
  MutationSequenceSelector({
    required this.predecessorMutation,
    required this.predecessorSlot,
    required Iterable<String> predecessorRelations,
    required Iterable<MutationSequenceCurrentPath> currentPaths,
  }) : predecessorRelations = List.unmodifiable(predecessorRelations),
       currentPaths = List.unmodifiable(currentPaths);

  final String predecessorMutation;
  final String predecessorSlot;
  final List<String> predecessorRelations;
  final List<MutationSequenceCurrentPath> currentPaths;
}

/// What the runtime needs to apply, queue, and encode one named mutation.
///
/// It is what a generated Mutation method builds from the exact record its
/// callback returned — the act's wire operations plus generated client-only
/// policy bound to those operations. A device-only companion is written
/// through the callback's own `tx` and never appears here (CAP-488).
///
/// [slotOperations] is flattened from the declared slots in declaration
/// order, list slots in element order — the execution order the schema
/// declared, not a convention the caller has to remember.
final class MutationRecord {
  MutationRecord({
    required this.name,
    this.version = 1,
    required Iterable<MutationSlotOperation> slotOperations,
    Iterable<SlotBinding> bindings = const [],
    Iterable<MutationSequenceSelector> sequenceSelectors = const [],
  }) : slotOperations = List.unmodifiable(slotOperations),
       bindings = List.unmodifiable(bindings),
       sequenceSelectors = List.unmodifiable(sequenceSelectors);

  /// The product verb this act is, as declared: `CreateMoment`.
  final String name;
  final int version;

  final List<MutationSlotOperation> slotOperations;

  List<ModelOperation> get operations =>
      List.unmodifiable(slotOperations.map((slot) => slot.operation));

  /// The act's declared wiring, one entry per bound row (spec
  /// 2026-08-16-slot-bindings). Empty when no slot binds.
  final List<SlotBinding> bindings;

  /// Client-only product ordering selectors.
  final List<MutationSequenceSelector> sequenceSelectors;
}
