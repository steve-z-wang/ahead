import '../api/model_writer.dart';
import '../schema/model_id.dart';
import '../storage/direct_model_writer.dart';
import 'model_mutation_writer.dart';
import 'transaction_context_factory.dart';

/// A direct write made inside a named act's callback (CAP-488).
///
/// It takes the full queued path — truth held aside, a queue row appended —
/// under the act's own ordinal, so it is provisional until the act settles and
/// rolls back with it. What it never does is reach the wire: the Backend has
/// no notion the operation exists, which is exactly what writing it through
/// the callback's transaction surface rather than returning it as a slot
/// declared.
final class CompanionModelWriter<I extends ModelId> implements ModelWriter<I> {
  const CompanionModelWriter(this.queued, this.mutationOrdinal);

  final ModelMutationWriter<I> queued;
  final int mutationOrdinal;

  @override
  Future<void> create(I id, Map<String, Object?> values) => queued.create(
    id,
    values,
    mutationOrdinal: mutationOrdinal,
    wire: false,
    slotName: null,
  );

  @override
  Future<void> update(I id, Map<String, Object?> patch) => queued.update(
    id,
    patch,
    mutationOrdinal: mutationOrdinal,
    wire: false,
    slotName: null,
  );

  @override
  Future<void> delete(I id) => queued.delete(
    id,
    mutationOrdinal: mutationOrdinal,
    wire: false,
    slotName: null,
  );
}

/// Routes each operation at entry time, so a captured outer Model collection
/// joins whichever Mutation fate is active rather than keeping the direct
/// writer it appeared to hold when the transaction was constructed.
final class TransactionModelWriter<I extends ModelId>
    implements ModelWriter<I> {
  const TransactionModelWriter({
    required this.context,
    required this.direct,
    required this.queued,
  });

  final TransactionFateContext context;
  final DirectModelWriter<I> direct;
  final ModelMutationWriter<I> queued;

  @override
  Future<void> create(I id, Map<String, Object?> values) =>
      context.runOperation((ordinal) {
        if (ordinal == null) return direct.create(id, values);
        return queued.create(
          id,
          values,
          mutationOrdinal: ordinal,
          wire: false,
          slotName: null,
        );
      });

  @override
  Future<void> update(I id, Map<String, Object?> patch) =>
      context.runOperation((ordinal) {
        if (ordinal == null) return direct.update(id, patch);
        return queued.update(
          id,
          patch,
          mutationOrdinal: ordinal,
          wire: false,
          slotName: null,
        );
      });

  @override
  Future<void> delete(I id) => context.runOperation((ordinal) {
    if (ordinal == null) return direct.delete(id);
    return queued.delete(
      id,
      mutationOrdinal: ordinal,
      wire: false,
      slotName: null,
    );
  });
}
