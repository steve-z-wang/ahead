import 'dart:async';

import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

import '../support/test_database.dart';

void main() {
  late TestLocalDatabase database;
  late ReadinessLedger ledger;

  setUp(() async {
    database = await TestLocalDatabase.open();
    ledger = ReadinessLedger(database.scope);
  });

  tearDown(() => database.close());

  test('deduplicates work and runs at most two attempts at once', () async {
    final attempts = <String>[];
    final completions = <String, Completer<PrerequisiteAttemptResult>>{};
    final runner = PrerequisiteRunner(
      ledger: ledger,
      handlers: PrerequisiteHandlerRegistry({
        'RemoteBlob': (arguments) {
          final key = arguments['key']! as String;
          attempts.add(key);
          return (completions[key] = Completer()).future;
        },
      }),
      retryDelay: (_) => Duration.zero,
    );
    final one = _blob('one');
    final two = _blob('two');
    final three = _blob('three');

    runner.reconcile([one, two, one, three]);
    await _waitUntil(() => attempts.length == 2);
    expect(attempts.toSet(), hasLength(2));

    completions[attempts.first]!.complete(PrerequisiteAttemptResult.ready);
    await _waitUntil(() => attempts.length == 3);
    expect(attempts.toSet(), {'one', 'two', 'three'});

    for (final entry in completions.entries) {
      if (!entry.value.isCompleted) {
        entry.value.complete(PrerequisiteAttemptResult.ready);
      }
    }
    await _waitUntil(
      () async =>
          await ledger.read(one) == ReadinessState.ready &&
          await ledger.read(two) == ReadinessState.ready &&
          await ledger.read(three) == ReadinessState.ready,
    );
    await runner.close();
  });

  test('retry uses engine backoff and permanent failure is durable', () async {
    var attempts = 0;
    final delays = <int>[];
    final retrying = _blob('retrying');
    final failed = _blob('failed');
    final runner = PrerequisiteRunner(
      ledger: ledger,
      handlers: PrerequisiteHandlerRegistry({
        'RemoteBlob': (arguments) async {
          if (arguments['key'] == 'failed') {
            return PrerequisiteAttemptResult.failed;
          }
          attempts += 1;
          return attempts == 1
              ? PrerequisiteAttemptResult.retry
              : PrerequisiteAttemptResult.ready;
        },
      }),
      retryDelay: (attempt) {
        delays.add(attempt);
        return Duration.zero;
      },
    );

    runner.reconcile([retrying, failed]);

    await _waitUntil(
      () async =>
          await ledger.read(retrying) == ReadinessState.ready &&
          await ledger.read(failed) == ReadinessState.failed,
    );
    expect(attempts, 2);
    expect(delays, [1]);
    await runner.close();
  });

  test('a completion is ignored after its invocation becomes stale', () async {
    final completion = Completer<PrerequisiteAttemptResult>();
    final invocation = _blob('stale');
    final runner = PrerequisiteRunner(
      ledger: ledger,
      handlers: PrerequisiteHandlerRegistry({
        'RemoteBlob': (_) => completion.future,
      }),
      retryDelay: (_) => Duration.zero,
    );

    runner.reconcile([invocation]);
    await Future<void>.delayed(Duration.zero);
    runner.reconcile(const []);
    completion.complete(PrerequisiteAttemptResult.ready);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(await ledger.read(invocation), ReadinessState.pending);
    await runner.close();
  });

  test('a handler failure arriving after close is ignored', () async {
    final completion = Completer<PrerequisiteAttemptResult>();
    final started = Completer<void>();
    final failures = <LocalSyncClientFailure>[];
    final runner = PrerequisiteRunner(
      ledger: ledger,
      handlers: PrerequisiteHandlerRegistry({
        'RemoteBlob': (_) {
          started.complete();
          return completion.future;
        },
      }),
      retryDelay: (_) => Duration.zero,
      failureObserver: failures.add,
    );

    runner.reconcile([_blob('closing')]);
    await started.future;
    await runner.close();
    completion.completeError(StateError('media catalog closed'));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(failures, isEmpty);
  });

  test(
    'an unexpected handler failure is reported once without a hot loop',
    () async {
      final secondAttempt = Completer<void>();
      final failures = <LocalSyncClientFailure>[];
      var attempts = 0;
      final runner = PrerequisiteRunner(
        ledger: ledger,
        handlers: PrerequisiteHandlerRegistry({
          'RemoteBlob': (_) async {
            attempts += 1;
            if (attempts == 1) throw StateError('broken handler');
            await secondAttempt.future;
            return PrerequisiteAttemptResult.retry;
          },
        }),
        retryDelay: (_) => Duration.zero,
        failureObserver: failures.add,
      );
      addTearDown(() async {
        if (!secondAttempt.isCompleted) secondAttempt.complete();
        await runner.close();
      });

      runner.reconcile([_blob('broken')]);
      await _waitUntil(() => failures.isNotEmpty);
      await Future<void>.delayed(Duration.zero);

      expect(failures, hasLength(1));
      expect(
        failures.single.boundary,
        LocalSyncClientFailureBoundary.prerequisite,
      );
      expect(failures.single.fate, LocalSyncClientFailureFate.continuing);
      expect(attempts, 1);
    },
  );

  test('a throwing observer leaves an unexpected invocation faulted', () async {
    var attempts = 0;
    final runner = PrerequisiteRunner(
      ledger: ledger,
      handlers: PrerequisiteHandlerRegistry({
        'RemoteBlob': (_) async {
          attempts += 1;
          throw StateError('handler');
        },
      }),
      retryDelay: (_) => Duration.zero,
      failureObserver: (_) => throw StateError('observer'),
    );

    runner.reconcile([_blob('broken')]);
    await _waitUntil(() => attempts == 1);
    await Future<void>.delayed(Duration.zero);
    runner.reconcile([_blob('broken')]);
    await Future<void>.delayed(Duration.zero);

    expect(attempts, 1);
    await runner.close();
  });
}

PrerequisiteInvocation _blob(String key) =>
    PrerequisiteInvocation(name: 'RemoteBlob', arguments: {'key': key});

Future<void> _waitUntil(FutureOr<bool> Function() condition) async {
  for (var attempt = 0; attempt < 200; attempt += 1) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError('condition was not reached');
}
