import '../projection/model_record.dart';
import '../schema/model_id.dart';
import '../schema/model_registry.dart';
import 'model_operation.dart';

/// The act-internal consistency check slot bindings declare (spec
/// 2026-08-16-slot-bindings): a bound row's referencing fields must equal the
/// bound slot's row identity.
///
/// A binding is a check and nothing else — no field is filled, no builder
/// changes shape. The check runs inside `mutate()`'s transaction, before
/// anything is written or queued, so a wrong id dies at the call site with a
/// stack trace instead of riding the queue to settlement and taking the whole
/// act down asynchronously. It reads where the truth of each operation kind
/// lives: a create's own payload; an update's or delete's row **as this act
/// leaves it** — the store's copy (main, or the before-image when the main
/// row has been optimistically purged) with the act's own EARLIER operations
/// on the same row folded in. The fold is what keeps a row created by one
/// slot and edited or deleted by a later slot of the same act checkable at
/// all: verify runs before any write, so the store cannot know that row yet,
/// and skipping it would make the one wiring mistake this check exists to
/// catch silent.
///
/// The server cannot trust any of this — the wire is a claim — so it runs its
/// own precheck over bound create rows and its resolvers still verify every
/// relationship against the database. This check disciplines our client, and
/// only ours.
final class SlotBindingVerifier {
  const SlotBindingVerifier({required this.registry});

  final ModelRegistry registry;

  /// Throws [ArgumentError] on the first bound row whose fields do not name
  /// its parent slot's row. Bindings are checked in declaration order.
  Future<void> verify(MutationRecord record) async {
    // One store read per (Model, row) however many bindings stand on it — a
    // bulk slot re-reading its parent per element would put the whole read
    // on the composer's hot path twice over.
    final stored = <String, ModelRecord<ModelId>?>{};
    for (final binding in record.bindings) {
      final expected = binding.parent.id.components.values.toList();
      if (binding.fields.length != expected.length) {
        // Generated facts and generated identities always agree; disagreeing
        // is a defect in generation, not a caller mistake.
        throw StateError(
          'mutation "${record.name}" binding on "${binding.operation.model}" '
          'names ${binding.fields.length} fields against an identity of '
          '${expected.length}',
        );
      }
      final actual = await _boundValues(record, binding, stored);
      // A row absent from the store, the before-images, and the act itself:
      // that update or delete is the store's own error downstream, and a
      // binding verdict about a row nobody holds would be invented.
      if (actual == null) continue;
      for (var index = 0; index < expected.length; index += 1) {
        if (actual[index] == expected[index]) continue;
        throw ArgumentError(
          'mutation "${record.name}" binds '
          '"${binding.operation.model}.${binding.fields[index]}" to the act\'s '
          '"${binding.parent.model}" row, but it names a different '
          '"${binding.parent.model}"',
        );
      }
    }
  }

  /// The bound fields' values as the act leaves this row: a create's payload;
  /// otherwise the row's effective state — stored truth with the act's
  /// earlier operations on the same row folded over it — under the update's
  /// patch where one applies. Null when there is no row to stand on anywhere.
  Future<List<Object?>?> _boundValues(
    MutationRecord record,
    SlotBinding binding,
    Map<String, ModelRecord<ModelId>?> stored,
  ) async {
    final operation = binding.operation;
    switch (operation) {
      case ModelCreateOperation():
        return [
          for (final field in binding.fields)
            operation.id.components[field] ?? operation.values[field],
        ];
      case ModelUpdateOperation():
        final row = await _effectiveRow(record, operation, stored);
        if (row == null) return null;
        return [
          for (final field in binding.fields)
            operation.patch.containsKey(field)
                ? operation.patch[field]
                : (operation.id.components[field] ?? row[field]),
        ];
      case ModelDeleteOperation():
        final row = await _effectiveRow(record, operation, stored);
        if (row == null) return null;
        return [
          for (final field in binding.fields)
            operation.id.components[field] ?? row[field],
        ];
    }
  }

  /// The row [operation] stands on, as the act has already shaped it: the
  /// store's copy — main first, the before-image when an optimistic purge
  /// took the main row — with every operation of this act that PRECEDES
  /// [operation] and names the same row folded in, in declaration order.
  Future<Map<String, Object?>?> _effectiveRow(
    MutationRecord record,
    ModelOperation operation,
    Map<String, ModelRecord<ModelId>?> stored,
  ) async {
    final key = _rowKey(operation);
    ModelRecord<ModelId>? held;
    if (stored.containsKey(key)) {
      held = stored[key];
    } else {
      final entry = registry[operation.model];
      held =
          await entry?.readMain(operation.id) ??
          await entry?.readBefore(operation.id);
      stored[key] = held;
    }
    var row = held == null
        ? null
        : <String, Object?>{...held.fields, ...held.id.components};
    for (final earlier in record.operations) {
      if (identical(earlier, operation)) break;
      if (earlier.model != operation.model) continue;
      if (_rowKey(earlier) != key) continue;
      switch (earlier) {
        case ModelCreateOperation():
          row = {...earlier.values, ...earlier.id.components};
        case ModelUpdateOperation():
          if (row != null) row = {...row, ...earlier.patch};
        case ModelDeleteOperation():
          row = null;
      }
    }
    return row;
  }

  String _rowKey(ModelOperation operation) {
    final components = operation.id.components;
    final buffer = StringBuffer(operation.model);
    for (final value in components.values) {
      buffer
        ..writeCharCode(0)
        ..write(value);
    }
    return buffer.toString();
  }
}
