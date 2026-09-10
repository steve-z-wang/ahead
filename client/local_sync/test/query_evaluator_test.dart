import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

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
      ModelFieldSchema(
        name: 'enabled',
        type: LocalScalarType.boolean,
        nullable: false,
      ),
      ModelFieldSchema(
        name: 'score',
        type: LocalScalarType.float,
        nullable: false,
      ),
      ModelFieldSchema(
        name: 'at',
        type: LocalScalarType.dateTime,
        nullable: false,
      ),
      ModelFieldSchema(
        name: 'note',
        type: LocalScalarType.string,
        nullable: true,
      ),
      ModelFieldSchema(
        name: 'kind',
        type: LocalEnumType(
          name: 'TestKind',
          values: {'personal', 'group'},
          encode: encodeTestKind,
          decode: decodeTestKind,
        ),
        nullable: false,
      ),
      ModelFieldSchema(
        name: 'spaceOrder',
        type: LocalScalarListType(LocalScalarType.uuid),
        nullable: false,
      ),
    ],
    uniqueConstraints: const [],
    relations: const [],
    createId: (components) => TestId(components['id']! as UUID),
  );
  final evaluator = QueryEvaluator<TestId>(schema);
  final name = SchemaModelField<String>('name');
  final enabled = SchemaModelField<bool>('enabled');
  final score = SchemaModelField<double>('score');
  final at = SchemaModelField<DateTime>('at');
  final note = SchemaModelField<String?>('note');
  final kind = SchemaModelField<TestKind>('kind');
  final spaceOrder = SchemaModelField<List<UUID>>('spaceOrder');
  final identity = ModelIdentityField<TestId>();

  final records = [
    record(2, name: 'Beta', enabled: true, score: 2, day: 2, note: null),
    record(1, name: 'Alpha', enabled: true, score: 2, day: 3, note: 'z'),
    record(3, name: 'Alpha', enabled: false, score: 1, day: 1, note: 'a'),
    record(4, name: 'Alpha', enabled: true, score: 2, day: 3, note: 'z'),
  ];

  test('applies AND predicates before ordering and limit', () {
    final result = evaluator.evaluate(
      records,
      ProjectionQuery(
        predicates: [enabled.equals(true), name.equals('Alpha')],
        order: [at.descending()],
        limit: 1,
      ),
    );

    expect(result.map((record) => record.id.number), [1]);
  });

  test('uses canonical identity as the final deterministic tie-breaker', () {
    final result = evaluator.evaluate(
      records,
      ProjectionQuery(order: [name.ascending(), score.ascending()]),
    );

    expect(result.map((record) => record.id.number), [3, 1, 4, 2]);
  });

  test('orders null first ascending and last descending', () {
    final ascending = evaluator.evaluate(
      records,
      ProjectionQuery(order: [note.ascending()]),
    );
    final descending = evaluator.evaluate(
      records,
      ProjectionQuery(order: [note.descending()]),
    );

    expect(ascending.first.id.number, 2);
    expect(descending.last.id.number, 2);
  });

  test('compares DateTimes as UTC instants and numbers numerically', () {
    final byTime = evaluator.evaluate(
      records,
      ProjectionQuery(order: [at.ascending(), score.descending()]),
    );

    expect(byTime.map((record) => record.id.number), [3, 2, 1, 4]);
  });

  test('supports identity equality and limit zero', () {
    expect(
      evaluator
          .evaluate(
            records,
            ProjectionQuery(predicates: [identity.equals(id(4))]),
          )
          .single
          .id,
      id(4),
    );
    expect(evaluator.evaluate(records, ProjectionQuery(limit: 0)), isEmpty);
  });

  test('supports enum equality but rejects enum ordering and list queries', () {
    final groups = evaluator.evaluate(
      records,
      ProjectionQuery(predicates: [kind.equals(TestKind.group)]),
    );
    expect(groups.map((record) => record.id.number), [2, 4]);
    expect(
      () => evaluator.evaluate(
        records,
        ProjectionQuery(order: [kind.ascending()]),
      ),
      throwsA(isA<ProjectionIntegrityException>()),
    );
    expect(
      () => evaluator.evaluate(
        records,
        ProjectionQuery(predicates: [spaceOrder.equals(const [])]),
      ),
      throwsA(isA<ProjectionIntegrityException>()),
    );
  });

  test('rejects negative limit and unknown fields', () {
    expect(
      () => evaluator.evaluate(records, ProjectionQuery(limit: -1)),
      throwsArgumentError,
    );
    expect(
      () => evaluator.evaluate(
        records,
        ProjectionQuery(
          predicates: [SchemaModelField<String>('missing').equals('x')],
        ),
      ),
      throwsA(isA<ProjectionIntegrityException>()),
    );
  });
}

ModelRecord<TestId> record(
  int idNumber, {
  required String name,
  required bool enabled,
  required double score,
  required int day,
  required String? note,
}) => ModelRecord(
  id: id(idNumber),
  fields: {
    'name': name,
    'enabled': enabled,
    'score': score,
    'at': DateTime.utc(2026, 8, day),
    'note': note,
    'kind': idNumber.isEven ? TestKind.group : TestKind.personal,
    'spaceOrder': <UUID>[],
  },
);

enum TestKind { personal, group }

String encodeTestKind(Object value) => (value as TestKind).name;

Object decodeTestKind(String wire) => TestKind.values.byName(wire);

TestId id(int number) => TestId(
  UUID.withValidation(
    '550e8400-e29b-41d4-a716-${number.toString().padLeft(12, '0')}',
  ),
);

final class TestId extends ModelId {
  const TestId(this.value);

  final UUID value;
  int get number => int.parse(value.uuid.substring(24));

  @override
  Map<String, Object> get components => {'id': value};

  @override
  bool operator ==(Object other) => other is TestId && other.value == value;

  @override
  int get hashCode => value.hashCode;
}
