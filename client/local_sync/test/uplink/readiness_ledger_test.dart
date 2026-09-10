import 'package:local_sync/local_sync.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:test/test.dart';

import '../support/test_database.dart';

void main() {
  late TestLocalDatabase database;
  late ReadinessLedger ledger;
  PrerequisiteInvocation invocation(String key) =>
      PrerequisiteInvocation(name: 'RemoteObject', arguments: {'key': key});

  setUp(() async {
    database = await TestLocalDatabase.open();
    ledger = ReadinessLedger(database.scope);
  });

  tearDown(() => database.close());

  test('an invocation with no terminal result is pending', () async {
    expect(
      await ledger.read(invocation('moments/a/photo.jpg')),
      ReadinessState.pending,
    );
  });

  test('typed invocation identity keeps prerequisite kinds separate', () async {
    final blob = PrerequisiteInvocation(
      name: 'RemoteBlob',
      arguments: {'key': 'shared'},
    );
    final thumbnail = PrerequisiteInvocation(
      name: 'RemoteThumbnail',
      arguments: {'key': 'shared'},
    );

    await ledger.markReady(blob);

    expect(await ledger.read(blob), ReadinessState.ready);
    expect(await ledger.read(thumbnail), ReadinessState.pending);
  });

  test('marks record the conclusion the worker reached', () async {
    await ledger.markReady(invocation('ready-key'));
    await ledger.markFailed(invocation('failed-key'));

    expect(await ledger.read(invocation('ready-key')), ReadinessState.ready);
    expect(await ledger.read(invocation('failed-key')), ReadinessState.failed);
  });

  test('marking twice is the same as marking once', () async {
    await ledger.markReady(invocation('key'));
    await ledger.markReady(invocation('key'));

    expect(await ledger.read(invocation('key')), ReadinessState.ready);
    expect(await _rowCount(database), 1);
  });

  test('the last write wins, in both directions', () async {
    await ledger.markReady(invocation('key'));
    await ledger.markFailed(invocation('key'));
    expect(await ledger.read(invocation('key')), ReadinessState.failed);

    // The ledger stores producer facts; the queue owns parking and discard.
    await ledger.markReady(invocation('key'));
    expect(await ledger.read(invocation('key')), ReadinessState.ready);
    expect(await _rowCount(database), 1);
  });

  test('a terminal result is legal before another queue read', () async {
    await ledger.markReady(invocation('key-written-first'));
    expect(
      await ledger.read(invocation('key-written-first')),
      ReadinessState.ready,
    );
  });

  test('keys do not read each other', () async {
    await ledger.markReady(invocation('one'));

    expect(await ledger.read(invocation('two')), ReadinessState.pending);
  });

  test('prune deletes exactly the keys it is given', () async {
    await ledger.markReady(invocation('keep'));
    await ledger.markFailed(invocation('drop-one'));
    await ledger.markReady(invocation('drop-two'));

    await ledger.prune([
      invocation('drop-one'),
      invocation('drop-two'),
      invocation('never-marked'),
    ]);

    expect(await ledger.read(invocation('keep')), ReadinessState.ready);
    expect(await ledger.read(invocation('drop-one')), ReadinessState.pending);
    expect(await ledger.read(invocation('drop-two')), ReadinessState.pending);
    expect(await _rowCount(database), 1);
  });

  test(
    'pruneUnreferenced spares candidates something still references',
    () async {
      await ledger.markReady(invocation('shared'));
      await ledger.markReady(invocation('lone'));

      // 'shared' is a candidate, but a surviving queued mutation still carries
      // it — so only 'lone' may go (CAP-521).
      await ledger.pruneUnreferenced(
        [invocation('shared'), invocation('lone')],
        [invocation('shared')],
      );

      expect(await ledger.read(invocation('shared')), ReadinessState.ready);
      expect(await ledger.read(invocation('lone')), ReadinessState.pending);
    },
  );

  test('pruning nothing touches nothing', () async {
    await ledger.markReady(invocation('keep'));

    await ledger.prune(const []);

    expect(await _rowCount(database), 1);
  });

  test('the table admits no state but the two conclusions', () async {
    // There is no third state to store: pending is the absence of a row, so a
    // row that claimed to be pending would be a second way to say nothing.
    await expectLater(
      database.scope.current.execute(
        DatabaseStatement(
          sql: "INSERT INTO readiness_states (key, state) VALUES ('k', 'x')",
        ),
      ),
      throwsA(anything),
    );
  });
}

Future<int> _rowCount(TestLocalDatabase database) async {
  final result = await database.scope.current.query(
    DatabaseQuery(sql: 'SELECT COUNT(*) AS count FROM readiness_states'),
  );
  return result[0]['count']! as int;
}
