import 'package:local_sync/local_sync.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:test/test.dart';

import '../support/test_database.dart';

void main() {
  final id = _TestId(
    UUID.withValidation('550e8400-e29b-41d4-a716-446655440000'),
  );
  final schema = ModelSchema<_TestId>(
    name: 'Test',
    identity: const ['id'],
    fields: const [
      ModelFieldSchema(name: 'id', type: LocalScalarType.uuid, nullable: false),
      ModelFieldSchema(
        name: 'name',
        type: LocalScalarType.string,
        nullable: false,
      ),
      ModelFieldSchema(
        name: 'note',
        type: LocalScalarType.string,
        nullable: true,
      ),
    ],
    uniqueConstraints: const [],
    relations: const [],
    createId: (components) => _TestId(components['id']! as UUID),
  );
  final syncSchema = schema;
  final descriptor = ModelDatabaseDescriptor<_TestId>(
    schema: schema,
    tableName: 'model_test',
    columns: const {'id': 'id', 'name': 'name', 'note': 'note'},
  );
  final beforeDescriptor = ModelDatabaseDescriptor<_TestId>(
    schema: schema,
    tableName: 'model_test_before',
    columns: const {'id': 'id', 'name': 'name', 'note': 'note'},
  );

  late TestLocalDatabase fixture;
  late ModelRegistry registry;

  setUp(() async {
    fixture = await TestLocalDatabase.open(
      modelStatements: [
        DatabaseStatement(
          sql: '''
            CREATE TABLE model_test (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              note TEXT
            )
          ''',
        ),
        DatabaseStatement(
          sql: '''
            CREATE TABLE model_test_before (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              note TEXT
            )
          ''',
        ),
      ],
    );
    // The write path is handed the whole roster of Models: a delete has to
    // reach the rows that fall with it, and only the registry knows them.
    registry = ModelRegistry([
      TypedModelRegistryEntry<_TestId>(
        schema: syncSchema,
        canonical: SqlCanonicalStore<_TestId>(
          database: fixture.scope,
          descriptor: descriptor,
        ),
        before: BeforeImageStore<_TestId>(
          database: fixture.scope,
          main: descriptor,
          before: beforeDescriptor,
        ),
        mutations: SqlMutationStore<_TestId>(
          database: fixture.scope,
          schema: syncSchema,
        ),
      ),
    ]);
  });

  tearDown(() => fixture.close());

  ModelRuntime<_TestId> buildRuntime() => ModelRuntime(
    database: fixture.scope,
    descriptor: descriptor,
    beforeDescriptor: beforeDescriptor,
    registry: registry,
  );

  Future<int> countQueued() async {
    final result = await fixture.database.query(
      DatabaseQuery(
        sql: 'SELECT COUNT(*) AS count FROM pending_mutation_operations',
      ),
    );
    return result.rows.single['count']! as int;
  }

  /// Drops the row's queue entries and rebuilds it — what a rejection does.
  Future<void> rejectPending(ModelRuntime<_TestId> runtime) async {
    await fixture.scope.transaction((_) async {
      await fixture.scope.current.execute(
        DatabaseStatement(sql: 'DELETE FROM pending_mutations'),
      );
    });
    await registry['Test']!.rebuild(id);
  }

  test('every Model gets one runtime with both write lanes', () {
    final runtime = buildRuntime();

    expect(runtime.direct, isA<DirectModelWriter<_TestId>>());
    expect(runtime.queued, isA<ModelMutationWriter<_TestId>>());
    // CAP-393 converged reads on one shape: the main table is the merged view,
    // so which lane last wrote the row changes nothing a reader does.
    expect(runtime.reader, isA<CanonicalModelReader<_TestId>>());
  });

  test('a direct write changes main and queues nothing', () async {
    final runtime = buildRuntime();

    await fixture.scope.transaction((_) async {
      await runtime.direct.create(id, {'name': 'First', 'note': null});
      await runtime.direct.update(id, const {});
      await runtime.direct.update(id, {'name': 'Second'});
    });

    expect((await runtime.reader.get(id))?.fields, {
      'name': 'Second',
      'note': null,
    });
    expect(await countQueued(), 0);
    // A clean row diverges from nothing, so no truth is held aside for it.
    expect(await runtime.before.exists(id), isFalse);

    await runtime.direct.delete(id);
    expect(await runtime.reader.get(id), isNull);
  });

  test('a companion holds truth aside and states wire = 0', () async {
    final runtime = buildRuntime();
    await runtime.canonical.create(id, {'name': 'Truth', 'note': 'kept'});

    final ordinal = await fixture.queueRecord();
    await CompanionModelWriter(
      runtime.queued,
      ordinal,
    ).update(id, {'name': 'Companion'});

    expect((await runtime.reader.get(id))?.fields['name'], 'Companion');
    expect((await runtime.before.read(id))?.fields['name'], 'Truth');
    final stored = await runtime.mutations.read(id);
    expect(stored.single.wire, isFalse);
  });

  test('a returned slot states wire = 1', () async {
    final runtime = buildRuntime();

    await runtime.queued.create(
      id,
      {'name': 'Projected', 'note': null},
      mutationOrdinal: await fixture.queueRecord(),
      wire: true,
    );

    // CAP-393: the main table IS the merged view, so the optimistic row is
    // there to be read. A create holds no before-image: the queue's create is
    // the marker that prior truth was nonexistence.
    expect((await runtime.reader.get(id))?.fields['name'], 'Projected');
    expect((await runtime.canonical.get(id))?.fields['name'], 'Projected');
    expect(await runtime.before.exists(id), isFalse);
    expect((await runtime.mutations.read(id)).single.wire, isTrue);
  });

  test('a rejection rebuilds a wire row and a companion alike', () async {
    final runtime = buildRuntime();
    await runtime.canonical.create(id, {'name': 'Truth', 'note': 'kept'});
    final ordinal = await fixture.queueRecord();
    await runtime.queued.update(
      id,
      {'name': 'Wire'},
      mutationOrdinal: ordinal,
      wire: true,
    );
    await CompanionModelWriter(
      runtime.queued,
      ordinal,
    ).update(id, {'name': 'Companion'});

    await rejectPending(runtime);

    expect((await runtime.reader.get(id))?.fields['name'], 'Truth');
    expect(await runtime.before.exists(id), isFalse);
  });

  test('acceptance ends a companion\'s rollback responsibility', () async {
    final runtime = buildRuntime();
    await runtime.canonical.create(id, {'name': 'Truth', 'note': 'kept'});
    final ordinal = await fixture.queueRecord();
    await CompanionModelWriter(
      runtime.queued,
      ordinal,
    ).update(id, {'name': 'Companion'});
    final settled = {
      for (final mutation in await runtime.mutations.read(id))
        mutation.position.mutationOrdinal,
    };

    // Acceptance is the only thing that can move a companion's truth: the
    // Backend never learns the operation existed, so no Downlink change will
    // ever name it (CAP-488). What ends here is the act's claim on the row —
    // nothing local will roll it back now. That is not ownership of the
    // field: the row is an ordinary row, and canonical state for it replaces
    // this value like any other.
    await registry['Test']!.advanceTruth(id, settled);

    expect(await runtime.before.exists(id), isFalse);
    expect((await runtime.reader.get(id))?.fields['name'], 'Companion');

    await registry['Test']!.upsert(id, {'name': 'Server', 'note': null});
    expect((await runtime.reader.get(id))?.fields['name'], 'Server');
  });

  test(
    'a rejection keeps the direct field and drops the pending one',
    () async {
      // The before-image is physically a whole row, but a direct write applies
      // only its own patch to both the visible row and that held base — so the
      // two lanes settle field by field.
      final runtime = buildRuntime();
      await runtime.canonical.create(id, {'name': 'Truth', 'note': 'original'});
      await runtime.queued.update(
        id,
        {'note': 'pending'},
        mutationOrdinal: await fixture.queueRecord(),
        wire: true,
      );

      await runtime.direct.update(id, {'name': 'Written'});
      await rejectPending(runtime);

      expect((await runtime.reader.get(id))?.fields, {
        'name': 'Written',
        'note': 'original',
      });
    },
  );

  test('the later write wins when both lanes move one field', () async {
    final runtime = buildRuntime();
    await runtime.canonical.create(id, {'name': 'Truth', 'note': 'kept'});
    await runtime.queued.update(
      id,
      {'name': 'Pending'},
      mutationOrdinal: await fixture.queueRecord(),
      wire: true,
    );

    await runtime.direct.update(id, {'name': 'Final'});
    await rejectPending(runtime);

    // The rejection removed only the optimism. A write nothing refused is
    // never undone.
    expect((await runtime.reader.get(id))?.fields['name'], 'Final');
  });

  test('a pending create then a direct update survives rejection', () async {
    final runtime = buildRuntime();
    // The row exists only because a pending act is creating it, so it holds no
    // truth at all — the queued create IS the marker that there was none.
    await runtime.queued.create(
      id,
      {'name': 'Optimistic', 'note': null},
      mutationOrdinal: await fixture.queueRecord(),
      wire: true,
    );
    expect(await runtime.before.exists(id), isFalse);

    await runtime.direct.update(id, {'name': 'Written'});
    // The direct write established the post-write row as local base truth.
    expect((await runtime.before.read(id))?.fields['name'], 'Written');

    await rejectPending(runtime);

    // Rejecting the remote create leaves the locally written row standing.
    expect((await runtime.reader.get(id))?.fields['name'], 'Written');
  });

  test('a pending create then a direct delete stays absent', () async {
    final runtime = buildRuntime();
    await runtime.queued.create(
      id,
      {'name': 'Optimistic', 'note': null},
      mutationOrdinal: await fixture.queueRecord(),
      wire: true,
    );

    await runtime.direct.delete(id);
    await rejectPending(runtime);

    expect(await runtime.reader.get(id), isNull);
    expect(await runtime.before.exists(id), isFalse);
  });

  test('a pending create, then a direct delete and create, survives', () async {
    // The delete drops the twin, so the create that follows lands on a dirty
    // row holding NO truth — the same state a queued create leaves, reached
    // the other way round. Without a base established here, refusing the
    // pending act would rebuild the row to nonexistence and purge writing
    // nothing refused.
    final runtime = buildRuntime();
    await runtime.queued.create(
      id,
      {'name': 'Optimistic', 'note': null},
      mutationOrdinal: await fixture.queueRecord(),
      wire: true,
    );

    await runtime.direct.delete(id);
    await runtime.direct.create(id, {'name': 'Recreated', 'note': 'kept'});
    expect((await runtime.before.read(id))?.fields['name'], 'Recreated');

    await rejectPending(runtime);

    expect((await runtime.reader.get(id))?.fields, {
      'name': 'Recreated',
      'note': 'kept',
    });
  });

  test('a pending update, then a direct delete and create, survives', () async {
    final runtime = buildRuntime();
    await runtime.canonical.create(id, {'name': 'Truth', 'note': 'original'});
    await runtime.queued.update(
      id,
      {'name': 'Pending'},
      mutationOrdinal: await fixture.queueRecord(),
      wire: true,
    );

    await runtime.direct.delete(id);
    await runtime.direct.create(id, {'name': 'Recreated', 'note': 'kept'});
    await rejectPending(runtime);

    // Exactly the values the caller committed — not the truth the act found,
    // which the final delete already made nonexistence.
    expect((await runtime.reader.get(id))?.fields, {
      'name': 'Recreated',
      'note': 'kept',
    });
  });

  test('a clean direct create holds no truth aside', () async {
    // Sparsity is the invariant that makes "has a before-image" mean "is
    // dirty": a row nothing is pending on has nothing to diverge from.
    final runtime = buildRuntime();

    await runtime.direct.create(id, {'name': 'Fresh', 'note': null});

    expect(await runtime.before.exists(id), isFalse);
    expect(await countQueued(), 0);
  });

  test('canonical state still replaces a locally written row', () async {
    // `write` means device-only TRANSMISSION, never permanent ownership of a
    // field (CAP-488): the Backend remains free to speak for the row, and what
    // it says replaces what was written here.
    final runtime = buildRuntime();
    await runtime.direct.create(id, {'name': 'Local', 'note': null});

    await registry['Test']!.upsert(id, {'name': 'Server', 'note': 'theirs'});

    expect((await runtime.reader.get(id))?.fields, {
      'name': 'Server',
      'note': 'theirs',
    });
  });
}

final class _TestId extends ModelId {
  const _TestId(this.value);

  final UUID value;

  @override
  Map<String, Object> get components => {'id': value};

  @override
  bool operator ==(Object other) => other is _TestId && other.value == value;

  @override
  int get hashCode => value.hashCode;
}
