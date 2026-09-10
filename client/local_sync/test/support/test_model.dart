import 'package:local_sync/local_sync.dart';
import 'package:local_sync_database/local_sync_database.dart';

/// The one Model the storage-level tests share: a main table, its before-image
/// twin, and the schema both descriptors read.
final testSchema = ModelSchema<TestId>(
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

final testDescriptor = ModelDatabaseDescriptor<TestId>(
  schema: testSchema,
  tableName: 'model_test',
  columns: const {'id': 'id', 'name': 'name', 'note': 'note'},
);

final testBeforeDescriptor = ModelDatabaseDescriptor<TestId>(
  schema: testSchema,
  tableName: 'model_test_before',
  columns: const {'id': 'id', 'name': 'name', 'note': 'note'},
);

final testModelStatements = <DatabaseStatement>[
  DatabaseStatement(
    sql: '''
      CREATE TABLE model_test (
        id TEXT NOT NULL,
        name TEXT NOT NULL,
        note TEXT,
        PRIMARY KEY (id)
      )
    ''',
  ),
  DatabaseStatement(
    sql: '''
      CREATE TABLE model_test_before (
        id TEXT NOT NULL,
        name TEXT NOT NULL,
        note TEXT,
        PRIMARY KEY (id)
      )
    ''',
  ),
];

TestId testId(int value) => TestId(
  UUID.withValidation(
    '550e8400-e29b-41d4-a716-${value.toString().padLeft(12, '0')}',
  ),
);

final idOne = testId(0);
final idTwo = testId(1);

final class TestId extends ModelId {
  const TestId(this.value);

  final UUID value;

  @override
  Map<String, Object> get components => {'id': value};

  @override
  bool operator ==(Object other) => other is TestId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'TestId($value)';
}
