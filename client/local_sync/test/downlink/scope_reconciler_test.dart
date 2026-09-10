import 'dart:async';

import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

import '../support/test_database.dart';

void main() {
  late TestLocalDatabase database;
  late ScopeStore store;
  late List<List<String>> installed;
  late ScopeReconciler reconciler;

  setUp(() async {
    database = await TestLocalDatabase.open();
    store = ScopeStore(database.scope);
    installed = [];
    reconciler = ScopeReconciler(
      store: store,
      replaceScopes: (scopes) async => installed.add([...scopes]),
      retryDelay: (_) async {},
    );
  });

  tearDown(() async {
    await reconciler.close();
    await database.close();
  });

  test('startup re-reads durable state without a fresh write', () async {
    await database.scope.transaction((_) => store.assignDirect(bookA, true));

    await reconciler.start();

    expect(installed, [
      [bookA],
    ]);
  });

  test('empty startup parks and a later commit wakes reconciliation', () async {
    await reconciler.start();
    expect(installed, [isEmpty]);

    await database.scope.transaction((_) => store.assignDirect(bookA, true));
    await eventually(() => installed.any((value) => value.contains(bookA)));
  });

  test('rollback emits no effective scope change', () async {
    await reconciler.start();
    final before = installed.length;
    await expectLater(
      database.scope.transaction((_) async {
        await store.assignDirect(bookA, true);
        throw StateError('rollback');
      }),
      throwsStateError,
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(installed.length, before);
  });

  test('replace failure retries from durable state until success', () async {
    var attempts = 0;
    reconciler = ScopeReconciler(
      store: store,
      replaceScopes: (scopes) async {
        attempts += 1;
        if (attempts == 1) throw StateError('transient');
        installed.add([...scopes]);
      },
      retryDelay: (_) async {},
    );
    await database.scope.transaction((_) => store.assignDirect(bookA, true));

    await reconciler.start();

    expect(attempts, 2);
    expect(installed.single, [bookA]);
  });

  test('reports one retrying failure per unsuccessful convergence', () async {
    final failures = <LocalSyncClientFailure>[];
    final firstError = StateError('first');
    final firstStack = StackTrace.fromString('first stack');
    Object errorToThrow = firstError;
    StackTrace stackToThrow = firstStack;
    var failuresRemaining = 2;
    reconciler = ScopeReconciler(
      store: store,
      replaceScopes: (scopes) async {
        if (failuresRemaining > 0) {
          failuresRemaining -= 1;
          Error.throwWithStackTrace(errorToThrow, stackToThrow);
        }
        installed.add([...scopes]);
      },
      retryDelay: (_) async {},
      failureObserver: failures.add,
    );
    await database.scope.transaction((_) => store.assignDirect(bookA, true));

    await reconciler.start();

    expect(failures, hasLength(1));
    expect(failures.single.error, same(firstError));
    expect(failures.single.stackTrace, same(firstStack));
    expect(failures.single.boundary, LocalSyncClientFailureBoundary.scopes);
    expect(failures.single.fate, LocalSyncClientFailureFate.retrying);

    final secondError = StateError('second');
    final secondStack = StackTrace.fromString('second stack');
    errorToThrow = secondError;
    stackToThrow = secondStack;
    failuresRemaining = 1;
    await database.scope.transaction((_) => store.assignDirect(bookA, false));
    await eventually(() => failures.length == 2);
    expect(failures.last.error, same(secondError));
    expect(failures.last.stackTrace, same(secondStack));
  });

  test('a throwing failure observer cannot stop convergence', () async {
    var attempts = 0;
    reconciler = ScopeReconciler(
      store: store,
      replaceScopes: (scopes) async {
        attempts += 1;
        if (attempts == 1) throw StateError('retry');
        installed.add([...scopes]);
      },
      retryDelay: (_) async {},
      failureObserver: (_) => throw StateError('observer'),
    );

    await reconciler.start();

    expect(attempts, 2);
    expect(installed.single, isEmpty);
  });

  test('a revision during replace drives the latest set again', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    reconciler = ScopeReconciler(
      store: store,
      replaceScopes: (scopes) async {
        installed.add([...scopes]);
        if (!entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      },
      retryDelay: (_) async {},
    );

    final starting = reconciler.start();
    await entered.future;
    await database.scope.transaction((_) => store.assignDirect(bookA, true));
    release.complete();
    await starting;
    await eventually(() => installed.last.contains(bookA));

    expect(installed.first, isEmpty);
    expect(installed.last, [bookA]);
  });
}

const bookA = 'Book:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

Future<void> eventually(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition did not become true');
}
