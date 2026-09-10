import 'mutation_queue_snapshot.dart';
import 'readiness_ledger.dart';

final class MutationScheduler {
  const MutationScheduler({required this.maxBytes, this.maxParents = 20});

  final int maxBytes;
  final int maxParents;

  List<int> select(
    QueueSnapshot snapshot, {
    required int Function(List<int> mutationOrdinals) encodedBytes,
  }) {
    if (maxBytes <= 0 || maxParents <= 0) return const [];
    if (snapshot.mutations.any(
      (mutation) => mutation.phase == MutationPhase.frozen,
    )) {
      return const [];
    }
    final legacyFifo = snapshot.mutations.any(
      (mutation) =>
          mutation.phase == MutationPhase.queued &&
          mutation.mutation.legacyFifo,
    );
    final selected = <int>[];
    final selectedSet = <int>{};
    final active = {
      for (final mutation in snapshot.mutations)
        if (mutation.phase != MutationPhase.accepted) mutation.mutation.ordinal,
    };

    for (final candidate in snapshot.mutations) {
      if (candidate.phase != MutationPhase.queued) continue;
      if (selected.length == maxParents) break;
      final runnable =
          candidate.readiness == ReadinessState.ready &&
          candidate.prerequisiteOrdinals.every(
            (ordinal) => !active.contains(ordinal),
          ) &&
          candidate.sequencePredecessorOrdinals.every(
            (ordinal) =>
                !active.contains(ordinal) || selectedSet.contains(ordinal),
          );
      if (!runnable) {
        if (legacyFifo) break;
        continue;
      }

      final proposed = [...selected, candidate.mutation.ordinal];
      if (selected.isNotEmpty && encodedBytes(proposed) > maxBytes) {
        if (legacyFifo) break;
        continue;
      }
      selected.add(candidate.mutation.ordinal);
      selectedSet.add(candidate.mutation.ordinal);
    }
    return List.unmodifiable(selected);
  }
}
