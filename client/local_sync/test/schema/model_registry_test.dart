import 'package:local_sync/local_sync.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:test/test.dart';

import '../support/test_database.dart';

void main() {
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
    ],
    uniqueConstraints: const [],
    relations: const [],
    createId: (parts) => TestId(parts['id']! as UUID),
  );
  final syncSchema = schema;
  final descriptor = ModelDatabaseDescriptor<TestId>(
    schema: schema,
    tableName: 'model_test',
    columns: const {'id': 'id', 'name': 'name'},
  );
  final beforeDescriptor = ModelDatabaseDescriptor<TestId>(
    schema: schema,
    tableName: 'model_test_before',
    columns: const {'id': 'id', 'name': 'name'},
  );

  late TestLocalDatabase fixture;

  setUp(() async {
    fixture = await TestLocalDatabase.open(
      modelStatements: [
        DatabaseStatement(
          sql:
              'CREATE TABLE model_test '
              '(id TEXT PRIMARY KEY, name TEXT NOT NULL)',
        ),
        DatabaseStatement(
          sql:
              'CREATE TABLE model_test_before '
              '(id TEXT PRIMARY KEY, name TEXT NOT NULL)',
        ),
      ],
    );
  });

  tearDown(() => fixture.close());

  TypedModelRegistryEntry<TestId> entryFor(
    ModelSchema<TestId> schema,
    CanonicalStore<TestId> canonical,
  ) => TypedModelRegistryEntry(
    schema: schema,
    canonical: canonical,
    before: BeforeImageStore(
      database: fixture.scope,
      main: descriptor,
      before: beforeDescriptor,
    ),
    mutations: SqlMutationStore(database: fixture.scope, schema: schema),
  );

  test('provides schema facts and typed Downlink forwarding', () async {
    final canonical = FakeCanonicalStore<TestId>();
    final registry = ModelRegistry([entryFor(syncSchema, canonical)]);
    final entry = registry['Test']!;
    final id = TestId(
      UUID.withValidation('550e8400-e29b-41d4-a716-446655440000'),
    );

    await entry.upsert(id, {'name': 'Family'});
    await entry.delete(id);

    expect(canonical.calls.map((call) => call.$1), ['upsert', 'purge']);
    expect(canonical.calls.map((call) => call.$2), everyElement(same(id)));
    expect(canonical.calls.map((call) => call.$3), [
      {'name': 'Family'},
      <String, Object?>{},
    ]);
  });

  test('rejects duplicate Model names', () {
    final canonical = FakeCanonicalStore<TestId>();
    final entry = entryFor(syncSchema, canonical);

    expect(() => ModelRegistry([entry, entry]), throwsStateError);
  });

  test('rejects an identity of the wrong generated type', () async {
    final registry = ModelRegistry([
      entryFor(syncSchema, FakeCanonicalStore<TestId>()),
    ]);

    await expectLater(
      registry['Test']!.delete(const OtherId()),
      throwsA(isA<LocalStorageException>()),
    );
  });
}

final class TestId extends ModelId {
  const TestId(this.id);
  final UUID id;

  @override
  Map<String, Object> get components => {'id': id};
}

final class OtherId extends ModelId {
  const OtherId();

  @override
  Map<String, Object> get components => const {'id': 'wrong'};
}

final class FakeCanonicalStore<I extends ModelId> implements CanonicalStore<I> {
  final calls = <(String, I, Map<String, Object?>)>[];

  @override
  Future<void> create(I id, Map<String, Object?> values) async {
    calls.add(('create', id, values));
  }

  @override
  Future<void> upsert(I id, Map<String, Object?> values) async {
    calls.add(('upsert', id, values));
  }

  @override
  Future<void> update(I id, Map<String, Object?> patch) async {
    calls.add(('update', id, patch));
  }

  @override
  Future<void> delete(I id) async {
    calls.add(('delete', id, const {}));
  }

  @override
  Future<void> purge(I id) async {
    calls.add(('purge', id, const {}));
  }

  @override
  Future<ModelRecord<I>?> get(I id) async => null;

  @override
  Future<List<ModelRecord<I>>> readAll() async => const [];

  @override
  Future<List<I>> identitiesMatching(Map<String, Object?> fieldValues) async =>
      const [];
}
