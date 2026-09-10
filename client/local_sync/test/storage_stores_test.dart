import 'package:local_sync/local_sync.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:test/test.dart';

import 'support/test_database.dart';

void main() {
  final id = TestId(
    UUID.withValidation('550e8400-e29b-41d4-a716-446655440000'),
  );
  final other = TestId(
    UUID.withValidation('550e8400-e29b-41d4-a716-446655440001'),
  );
  final schema = ModelSchema<TestId>(
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
    createId: (components) => TestId(components['id']! as UUID),
  );
  final descriptor = ModelDatabaseDescriptor<TestId>(
    schema: schema,
    tableName: 'model_test',
    columns: const {'id': 'id', 'name': 'name', 'note': 'note'},
  );
  final beforeDescriptor = ModelDatabaseDescriptor<TestId>(
    schema: schema,
    tableName: 'model_test_before',
    columns: const {'id': 'id', 'name': 'name', 'note': 'note'},
  );
  final syncSchema = schema;

  late TestLocalDatabase fixture;
  late SqlMutationStore<TestId> mutations;
  late SqlCanonicalStore<TestId> canonical;
  late BeforeImageStore<TestId> before;

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
    mutations = SqlMutationStore(database: fixture.scope, schema: syncSchema);
    canonical = SqlCanonicalStore(
      database: fixture.scope,
      descriptor: descriptor,
    );
    before = BeforeImageStore(
      database: fixture.scope,
      main: descriptor,
      before: beforeDescriptor,
    );
  });

  tearDown(() => fixture.close());

  test('mutation writer appends durable rows and skips empty update', () async {
    final writer = ModelMutationWriter(
      mutations,
      before: before,
      main: canonical,
    );

    // Each write is its own named act, so each queues its own record first:
    // there are no anonymous mutations (CAP-444).
    await writer.create(
      id,
      {'name': 'Family'},
      mutationOrdinal: await fixture.queueRecord(),
      wire: true,
    );
    await writer.update(
      id,
      const {},
      mutationOrdinal: await fixture.queueRecord(),
      wire: true,
    );
    await writer.update(
      id,
      {'note': 'Later'},
      mutationOrdinal: await fixture.queueRecord(),
      wire: true,
    );
    await writer.delete(
      id,
      mutationOrdinal: await fixture.queueRecord(),
      wire: true,
    );

    final stored = await mutations.read(id);
    expect(stored, hasLength(3));
    expect(stored.map((row) => row.operation), [
      MutationOperation.create,
      MutationOperation.update,
      MutationOperation.delete,
    ]);
  });

  test('mutation storage rejects malformed persisted rows', () async {
    final record = await fixture.queueRecord();
    await expectLater(
      fixture.database.execute(
        DatabaseStatement(
          sql: '''
            INSERT INTO pending_mutation_operations
              (mutation_ordinal, position, model, identity_json, operation,
               values_json, is_uplink)
            VALUES (?, 0, ?, ?, ?, ?, 1)
          ''',
          variables: [
            record,
            'Test',
            '{"id":"550e8400-e29b-41d4-a716-446655440000"}',
            'upsert',
            '{}',
          ],
        ),
      ),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('canonical store creates and enforces strict row counts', () async {
    await canonical.create(id, {'name': 'Canonical'});
    expect((await canonical.get(id))?.fields, {
      'name': 'Canonical',
      'note': null,
    });
    await canonical.update(id, {'note': 'Updated'});
    expect((await canonical.get(id))?.fields['note'], 'Updated');
    await canonical.delete(id);
    expect(await canonical.get(id), isNull);

    expect(
      () => canonical.update(id, {'name': 'Missing'}),
      throwsA(isA<LocalStorageException>()),
    );
    expect(() => canonical.delete(id), throwsA(isA<LocalStorageException>()));
  });

  test(
    'canonical create validates complete values without a mutation',
    () async {
      expect(
        () => canonical.create(other, const {}),
        throwsA(isA<LocalStorageException>()),
      );
      expect(await mutations.readAll(), isEmpty);
    },
  );

  test(
    'canonical upsert replaces full state and purge is idempotent',
    () async {
      await canonical.upsert(id, {'name': 'Canonical', 'note': 'Old'});
      await canonical.upsert(id, {'name': 'Replacement', 'note': null});
      expect((await canonical.get(id))?.fields, {
        'name': 'Replacement',
        'note': null,
      });

      await canonical.purge(id);
      await canonical.purge(id);
      expect(await canonical.get(id), isNull);
    },
  );
}

final class TestId extends ModelId {
  const TestId(this.value);

  final UUID value;

  @override
  Map<String, Object> get components => {'id': value};

  @override
  bool operator ==(Object other) => other is TestId && other.value == value;

  @override
  int get hashCode => value.hashCode;
}
