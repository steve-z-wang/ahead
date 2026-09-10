import '../mutation/mutation_store.dart';
import 'prerequisite.dart';
import 'readiness_ledger.dart';

enum MutationPhase { queued, frozen, accepted }

final class QueuedMutationSnapshot {
  QueuedMutationSnapshot({
    required this.mutation,
    required this.phase,
    required Iterable<StoredMutationOperation> operations,
    required Iterable<int> prerequisiteOrdinals,
    required Iterable<int> sequencePredecessorOrdinals,
    Iterable<PrerequisiteInvocation> prerequisites = const [],
    required this.readiness,
  }) : operations = List.unmodifiable(operations),
       prerequisiteOrdinals = Set.unmodifiable(prerequisiteOrdinals),
       sequencePredecessorOrdinals = Set.unmodifiable(
         sequencePredecessorOrdinals,
       ),
       prerequisites = Set.unmodifiable(prerequisites);

  final StoredMutation mutation;
  final MutationPhase phase;
  final List<StoredMutationOperation> operations;
  final Set<int> prerequisiteOrdinals;
  final Set<int> sequencePredecessorOrdinals;
  final Set<PrerequisiteInvocation> prerequisites;
  final ReadinessState readiness;
}

final class QueueSnapshot {
  QueueSnapshot(
    Iterable<QueuedMutationSnapshot> mutations, {
    this.clientId = '',
    this.nextBatchSequence = 1,
  }) : mutations = _ordered(mutations);

  final List<QueuedMutationSnapshot> mutations;
  final String clientId;
  final int nextBatchSequence;

  QueuedMutationSnapshot? operator [](int ordinal) =>
      _byOrdinal(mutations)[ordinal];

  static List<QueuedMutationSnapshot> _ordered(
    Iterable<QueuedMutationSnapshot> source,
  ) {
    final result = source.toList()
      ..sort(
        (left, right) =>
            left.mutation.ordinal.compareTo(right.mutation.ordinal),
      );
    final ordinals = <int>{};
    for (final mutation in result) {
      if (!ordinals.add(mutation.mutation.ordinal)) {
        throw ArgumentError('duplicate mutation ordinal');
      }
    }
    return List.unmodifiable(result);
  }

  static Map<int, QueuedMutationSnapshot> _byOrdinal(
    Iterable<QueuedMutationSnapshot> mutations,
  ) => {for (final mutation in mutations) mutation.mutation.ordinal: mutation};
}
