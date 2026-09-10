import '../schema/model_id.dart';

enum MutationOperation { create, update, delete }

final class MutationPosition implements Comparable<MutationPosition> {
  const MutationPosition({
    required this.mutationOrdinal,
    required this.operationPosition,
  });

  final int mutationOrdinal;
  final int operationPosition;

  @override
  int compareTo(MutationPosition other) {
    final parent = mutationOrdinal.compareTo(other.mutationOrdinal);
    return parent != 0
        ? parent
        : operationPosition.compareTo(other.operationPosition);
  }

  @override
  bool operator ==(Object other) =>
      other is MutationPosition &&
      other.mutationOrdinal == mutationOrdinal &&
      other.operationPosition == operationPosition;

  @override
  int get hashCode => Object.hash(mutationOrdinal, operationPosition);

  @override
  String toString() => '$mutationOrdinal:$operationPosition';
}

final class ModelMutation<I extends ModelId> {
  ModelMutation({
    required this.position,
    required this.id,
    required this.operation,
    required Map<String, Object?> values,
    this.wire = true,
    this.inherited = false,
  }) : values = Map.unmodifiable(values);

  final MutationPosition position;

  final I id;
  final MutationOperation operation;
  final Map<String, Object?> values;

  /// Whether the Backend receives this operation (CAP-488).
  ///
  /// False for a device-only companion — a direct write made inside a named
  /// act's callback, which shares the act's fate but never its wire.
  final bool wire;

  /// Whether this delete came down a Cascade relation rather than from the
  /// queue.
  ///
  /// The queue holds one entry per action — the row the user named — so a
  /// descendant's delete exists only as this, synthesized at replay from the
  /// ancestor's pending delete and borrowing its position. It is absorbing: a
  /// row already gone simply stays gone, where a user's own delete of an
  /// absent row is an integrity failure.
  final bool inherited;
}
