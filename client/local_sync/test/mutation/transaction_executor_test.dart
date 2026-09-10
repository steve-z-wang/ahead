import 'dart:async';

import 'package:local_sync/local_sync.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:test/test.dart';

import '../support/cascade_family.dart';
import '../support/test_database.dart';

void main() {
  test('transaction context refuses to close over unawaited work', () async {
    final context = TransactionFateContext();
    final entered = Completer<void>();
    final release = Completer<void>();
    final operation = context.runOperation((_) async {
      entered.complete();
      await release.future;
    });
    await entered.future;

    expect(context.close, throwsStateError);

    release.complete();
    await operation;
    context.close();
  });

  late TestLocalDatabase fixture;
  late FamilyRegistry family;
  late FamilyRuntimes runtimes;

  final spaceId = FamilySpaceId(familyUuid(1));
  final momentId = FamilyMomentId(familyUuid(2));

  setUp(() async {
    fixture = await TestLocalDatabase.open(
      modelStatements: familyModelStatements,
    );
    family = FamilyRegistry(fixture.scope);
    runtimes = FamilyRuntimes(fixture.scope, family.registry);
    await family.space.create(spaceId, {'name': 'book'});
  });

  tearDown(() => fixture.close());

  MutationRecord page(String name, int id) => familyMutationRecord(
    name: name,
    operations: [
      ModelCreateOperation(
        model: 'FamilyMoment',
        id: FamilyMomentId(familyUuid(id)),
        values: {'spaceId': spaceId.value, 'caption': name},
      ),
    ],
  );

  Future<List<DatabaseRow>> records() async =>
      (await fixture.scope.current.query(
        DatabaseQuery(
          sql: 'SELECT ordinal, name FROM pending_mutations ORDER BY ordinal',
        ),
      )).rows.toList();

  test(
    'outer transaction returns after committing every direct write',
    () async {
      final first = FamilyTagId(familyUuid(10));
      final second = FamilyTagId(familyUuid(11));

      final result = await runtimes.transaction((tx) async {
        await tx.models.tag.create(first, {'momentId': momentId.value});
        await tx.models.tag.create(second, {'momentId': momentId.value});
        return 42;
      });

      expect(result, 42);
      expect(await runtimes.tag.reader.get(first), isNotNull);
      expect(await runtimes.tag.reader.get(second), isNotNull);
      expect(await records(), isEmpty);
    },
  );

  test('outer error rolls back direct writes and released mutations', () async {
    final tagId = FamilyTagId(familyUuid(12));

    await expectLater(
      runtimes.transaction((tx) async {
        await tx.models.tag.create(tagId, {'momentId': momentId.value});
        await tx.mutate.apply(page('CapturePage', 20));
        throw StateError('outer failed');
      }),
      throwsStateError,
    );

    expect(await runtimes.tag.reader.get(tagId), isNull);
    expect(
      await runtimes.moment.reader.get(FamilyMomentId(familyUuid(20))),
      isNull,
    );
    expect(await records(), isEmpty);
  });

  test('sequential mutations commit as distinct records', () async {
    await runtimes.transaction((tx) async {
      await tx.mutate.apply(page('FirstPage', 21));
      await tx.mutate.apply(page('SecondPage', 22));
    });

    expect(
      records().then((rows) => rows.map((row) => row['name'])),
      completion(['FirstPage', 'SecondPage']),
    );
  });

  test(
    'null mutation rolls back its savepoint and outer work continues',
    () async {
      final rolledBack = FamilyTagId(familyUuid(13));
      final kept = FamilyTagId(familyUuid(14));

      await runtimes.transaction((tx) async {
        await tx.mutate.nothing(
          'Nothing',
          companions: (models) =>
              models.tag.create(rolledBack, {'momentId': momentId.value}),
        );
        await tx.models.tag.create(kept, {'momentId': momentId.value});
      });

      expect(await runtimes.tag.reader.get(rolledBack), isNull);
      expect(await runtimes.tag.reader.get(kept), isNotNull);
      expect(await records(), isEmpty);
    },
  );

  test(
    'caught mutation error rolls back its savepoint and outer work continues',
    () async {
      final rolledBack = FamilyTagId(familyUuid(17));
      final kept = FamilyTagId(familyUuid(18));

      await runtimes.transaction((tx) async {
        try {
          await tx.mutate.run<({ModelOperation operation})>(
            name: 'BrokenPage',
            build: (mutation) async {
              await mutation.models.tag.create(rolledBack, {
                'momentId': momentId.value,
              });
              throw StateError('callback failed');
            },
            record: (result) => familyMutationRecord(
              name: 'BrokenPage',
              operations: [result.operation],
            ),
          );
        } on StateError {
          // The caller deliberately keeps the outer transaction alive.
        }
        await tx.models.tag.create(kept, {'momentId': momentId.value});
      });

      expect(await runtimes.tag.reader.get(rolledBack), isNull);
      expect(await runtimes.tag.reader.get(kept), isNotNull);
      expect(await records(), isEmpty);
    },
  );

  test('captured outer models join the active mutation fate', () async {
    final companion = FamilyTagId(familyUuid(15));

    await runtimes.transaction((tx) async {
      await tx.mutate.apply(
        page('CapturePage', 23),
        companions: (_) =>
            tx.models.tag.create(companion, {'momentId': momentId.value}),
      );
    });

    final operations = await fixture.scope.current.query(
      DatabaseQuery(
        sql:
            'SELECT model, is_uplink FROM pending_mutation_operations '
            'ORDER BY position',
      ),
    );
    expect(operations.rows.map((row) => (row['model'], row['is_uplink'])), [
      ('FamilyTag', 0),
      ('FamilyMoment', 1),
    ]);
  });

  test('direct and captured scope writes follow transaction fate', () async {
    const directScope = 'Book:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const companionScope = 'Book:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

    await runtimes.transaction((tx) async {
      await tx.scopes.set(directScope);
      await tx.mutate.apply(
        page('CapturePage', 27),
        companions: (_) => tx.scopes.set(companionScope),
      );
    });

    expect(await ScopeStore(fixture.scope).effectiveDesiredScopes(), [
      directScope,
      companionScope,
    ]);
    final pending = await fixture.scope.current.query(
      DatabaseQuery(sql: 'SELECT scope, desired FROM pending_mutation_scopes'),
    );
    expect(pending.rows.map((row) => (row['scope'], row['desired'])), [
      (companionScope, 1),
    ]);
  });

  test(
    'scope work rolls back with its own savepoint and outer error',
    () async {
      const rolledBackMutation = 'Book:cccccccc-cccc-4ccc-8ccc-cccccccccccc';
      const rolledBackOuter = 'Book:dddddddd-dddd-4ddd-8ddd-dddddddddddd';

      await runtimes.transaction((tx) async {
        await tx.mutate.nothing(
          'Nothing',
          companions: (_) => tx.scopes.set(rolledBackMutation),
        );
      });
      expect(await ScopeStore(fixture.scope).effectiveDesiredScopes(), isEmpty);

      await expectLater(
        runtimes.transaction((tx) async {
          await tx.scopes.set(rolledBackOuter);
          throw StateError('outer failed');
        }),
        throwsStateError,
      );
      expect(await ScopeStore(fixture.scope).effectiveDesiredScopes(), isEmpty);
    },
  );

  test('active mutation rejects a nested sibling mutation', () async {
    final entered = Completer<void>();
    final release = Completer<void>();

    await runtimes.transaction((tx) async {
      final first = tx.mutate.apply(
        page('FirstPage', 24),
        companions: (_) async {
          entered.complete();
          await release.future;
        },
      );
      await entered.future;

      await expectLater(
        tx.mutate.apply(page('SecondPage', 25)),
        throwsStateError,
      );
      release.complete();
      await first;
    });

    expect(
      records().then((rows) => rows.map((row) => row['name'])),
      completion(['FirstPage']),
    );
  });

  test('active mutation rejects concurrent direct sibling access', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final sibling = FamilyTagId(familyUuid(16));

    await runtimes.transaction((tx) async {
      final first = tx.mutate.apply(
        page('FirstPage', 26),
        companions: (_) async {
          entered.complete();
          await release.future;
        },
      );
      await entered.future;

      await expectLater(
        tx.models.tag.create(sibling, {'momentId': momentId.value}),
        throwsStateError,
      );
      release.complete();
      await first;
    });

    expect(await runtimes.tag.reader.get(sibling), isNull);
  });
}
