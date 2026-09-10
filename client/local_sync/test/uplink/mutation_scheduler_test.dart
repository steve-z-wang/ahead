import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

void main() {
  const scheduler = MutationScheduler(maxBytes: 100, maxParents: 20);

  List<int> select(
    List<QueuedMutationSnapshot> mutations, {
    Map<int, int> sizes = const {},
  }) {
    final snapshot = QueueSnapshot(mutations);
    return scheduler.select(
      snapshot,
      encodedBytes: (ordinals) =>
          ordinals.fold(0, (total, id) => total + (sizes[id] ?? 1)),
    );
  }

  test('readiness-blocked work does not stop unrelated work', () {
    expect(
      select([
        mutation(1, readiness: ReadinessState.pending),
        mutation(2),
        mutation(3),
      ]),
      [2, 3],
    );
  });

  test('a sequence predecessor can share the same batch', () {
    expect(
      select([
        mutation(1),
        mutation(2, sequencePredecessors: const [1]),
      ]),
      [1, 2],
    );
  });

  test('a lifecycle prerequisite cannot share its first request', () {
    expect(
      select([
        mutation(1),
        mutation(2, prerequisites: const [1]),
        mutation(3),
      ]),
      [1, 3],
    );
  });

  test('dependent work cannot pass its skipped predecessor', () {
    expect(
      select([
        mutation(1, readiness: ReadinessState.pending),
        mutation(2, sequencePredecessors: const [1]),
        mutation(3),
      ]),
      [3],
    );
  });

  test('accepted or absent predecessors satisfy both edge types', () {
    expect(
      select([
        mutation(1, phase: MutationPhase.accepted),
        mutation(
          2,
          prerequisites: const [1, 99],
          sequencePredecessors: const [1, 99],
        ),
      ]),
      [2],
    );
  });

  test('direct sequence edges transit through the candidate scan', () {
    expect(
      select([
        mutation(1),
        mutation(2, sequencePredecessors: const [1]),
        mutation(3, sequencePredecessors: const [2]),
      ]),
      [1, 2, 3],
    );
  });

  test('skips an unrelated oversized candidate and keeps packing', () {
    expect(
      select(
        [mutation(1), mutation(2), mutation(3)],
        sizes: const {1: 40, 2: 80, 3: 50},
      ),
      [1, 3],
    );
  });

  test('one oversized act is selected when the batch is empty', () {
    expect(select([mutation(2)], sizes: const {2: 101}), [2]);
  });

  test('limits the batch to twenty parents', () {
    expect(
      select([
        for (var ordinal = 1; ordinal <= 21; ordinal += 1) mutation(ordinal),
      ]),
      [for (var ordinal = 1; ordinal <= 20; ordinal += 1) ordinal],
    );
  });

  test('legacy FIFO work prevents a post-upgrade overtake', () {
    expect(
      select([
        mutation(1, readiness: ReadinessState.pending, legacyFifo: true),
        mutation(2),
      ]),
      isEmpty,
    );
  });
}

QueuedMutationSnapshot mutation(
  int ordinal, {
  List<int> prerequisites = const [],
  List<int> sequencePredecessors = const [],
  MutationPhase phase = MutationPhase.queued,
  ReadinessState readiness = ReadinessState.ready,
  bool legacyFifo = false,
}) => QueuedMutationSnapshot(
  mutation: StoredMutation(
    ordinal: ordinal,
    name: 'M$ordinal',
    legacyFifo: legacyFifo,
  ),
  phase: phase,
  operations: const [],
  prerequisiteOrdinals: prerequisites,
  sequencePredecessorOrdinals: sequencePredecessors,
  readiness: readiness,
);
