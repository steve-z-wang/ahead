import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

void main() {
  final tenant = UUID.withValidation('550e8400-e29b-41d4-a716-446655440000');
  final schema = ModelSchema<TestId>(
    name: 'Test',
    identity: const ['tenantId', 'number'],
    fields: const [
      ModelFieldSchema(
        name: 'tenantId',
        type: LocalScalarType.uuid,
        nullable: false,
      ),
      ModelFieldSchema(
        name: 'number',
        type: LocalScalarType.int,
        nullable: false,
      ),
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
        name: 'ratio',
        type: LocalScalarType.float,
        nullable: true,
      ),
      ModelFieldSchema(
        name: 'capturedAt',
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
    createId: (components) => TestId(
      tenantId: components['tenantId']! as UUID,
      number: components['number']! as int,
    ),
  );
  const codec = LocalValueCodec();

  test('round trips canonical scalar and composite identity JSON', () {
    final id = TestId(tenantId: tenant, number: 7);

    final encodedId = codec.encodeIdentity(schema, id);
    final encodedValues = codec.encodeValues(schema, {
      'ratio': 1.5,
      'note': null,
      'name': 'Family',
      'enabled': true,
      'capturedAt': DateTime.parse('2026-08-03T01:02:03-07:00'),
    });

    expect(
      encodedId,
      '{"number":7,"tenantId":"550e8400-e29b-41d4-a716-446655440000"}',
    );
    expect(
      encodedValues,
      '{"capturedAt":"2026-08-03T08:02:03.000Z","enabled":true,'
      '"name":"Family","note":null,"ratio":1.5}',
    );
    expect(codec.decodeIdentity(schema, encodedId), id);
    expect(codec.decodeValues(schema, encodedValues), {
      'capturedAt': DateTime.utc(2026, 8, 3, 8, 2, 3),
      'enabled': true,
      'name': 'Family',
      'note': null,
      'ratio': 1.5,
    });
  });

  for (final invalid in <({String name, String json})>[
    (name: 'malformed JSON', json: '{'),
    (name: 'non-object JSON', json: '[]'),
    (name: 'unknown field', json: '{"other":1}'),
    (name: 'identity in values', json: '{"number":1}'),
    (name: 'wrong scalar type', json: '{"enabled":"yes"}'),
    (name: 'invalid UUID', json: '{"tenantId":"not-a-uuid","number":1}'),
    (name: 'non-finite float string', json: '{"ratio":"NaN"}'),
  ]) {
    test('rejects ${invalid.name}', () {
      final decode = invalid.name == 'invalid UUID'
          ? () => codec.decodeIdentity(schema, invalid.json)
          : () => codec.decodeValues(schema, invalid.json);
      expect(decode, throwsA(isA<LocalDataException>()));
    });
  }

  test('rejects missing and extra identity components on encode', () {
    expect(
      () => codec.encodeIdentity(schema, const IncompleteTestId()),
      throwsA(isA<LocalDataException>()),
    );
  });

  test('rejects non-finite floats on encode', () {
    expect(
      () => codec.encodeValues(schema, {'ratio': double.nan}),
      throwsA(isA<LocalDataException>()),
    );
  });

  test('round trips closed enums and immutable ordered scalar lists', () {
    final second = UUID.withValidation('550e8400-e29b-41d4-a716-446655440001');

    final encoded = codec.encodeValues(schema, {
      'kind': TestKind.group,
      'spaceOrder': [tenant, second],
    });
    final decoded = codec.decodeValues(schema, encoded);

    expect(
      encoded,
      '{"kind":"group","spaceOrder":['
      '"550e8400-e29b-41d4-a716-446655440000",'
      '"550e8400-e29b-41d4-a716-446655440001"]}',
    );
    expect(decoded['kind'], TestKind.group);
    expect(decoded['spaceOrder'], [tenant, second]);
    expect(
      () => (decoded['spaceOrder']! as List).add(tenant),
      throwsUnsupportedError,
    );
  });

  test('rejects unknown enums and invalid scalar-list elements', () {
    expect(
      () => codec.decodeValues(schema, '{"kind":"unknown"}'),
      throwsA(isA<LocalDataException>()),
    );
    expect(
      () => codec.decodeValues(
        schema,
        '{"spaceOrder":["550e8400-e29b-41d4-a716-446655440000",7]}',
      ),
      throwsA(isA<LocalDataException>()),
    );
  });

  test('round trips enum and scalar-list text storage', () {
    final second = UUID.withValidation('550e8400-e29b-41d4-a716-446655440001');
    final kind = schema.fieldsByName['kind']!;
    final spaceOrder = schema.fieldsByName['spaceOrder']!;

    expect(codec.encodeTextStorage(kind, TestKind.group), 'group');
    expect(codec.decodeTextStorage<TestKind>(kind, 'group'), TestKind.group);
    final encoded = codec.encodeTextStorage(spaceOrder, [tenant, second]);
    final decoded = codec.decodeListTextStorage<UUID>(spaceOrder, encoded);

    expect(
      encoded,
      '["550e8400-e29b-41d4-a716-446655440000",'
      '"550e8400-e29b-41d4-a716-446655440001"]',
    );
    expect(decoded, [tenant, second]);
    expect(() => decoded.add(tenant), throwsUnsupportedError);
  });
}

enum TestKind { personal, group }

String encodeTestKind(Object value) => (value as TestKind).name;

Object decodeTestKind(String wire) => TestKind.values.byName(wire);

final class TestId extends ModelId {
  const TestId({required this.tenantId, required this.number});

  final UUID tenantId;
  final int number;

  @override
  Map<String, Object> get components => {
    'tenantId': tenantId,
    'number': number,
  };

  @override
  bool operator ==(Object other) =>
      other is TestId && other.tenantId == tenantId && other.number == number;

  @override
  int get hashCode => Object.hash(tenantId, number);
}

final class IncompleteTestId extends ModelId {
  const IncompleteTestId();

  @override
  Map<String, Object> get components => const {'number': 1};
}
