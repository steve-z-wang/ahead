import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

void main() {
  final id = TestId(
    UUID.withValidation('550e8400-e29b-41d4-a716-446655440000'),
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
  final reducer = MutationReducer<TestId>(schema);

  ModelMutation<TestId> mutation(
    int ordinal,
    MutationOperation operation, [
    Map<String, Object?> values = const {},
  ]) => ModelMutation(
    position: MutationPosition(mutationOrdinal: ordinal, operationPosition: 0),
    id: id,
    operation: operation,
    values: values,
  );

  test('folds create and fills omitted nullable fields', () {
    final projected = reducer.reduce(null, [
      mutation(1, MutationOperation.create, {'name': 'Family'}),
    ]);

    expect(
      projected,
      ModelRecord(id: id, fields: const {'name': 'Family', 'note': null}),
    );
  });

  test('folds updates by ordinal and returns an immutable snapshot', () {
    final canonical = ModelRecord(
      id: id,
      fields: const {'name': 'Before', 'note': null},
    );

    final projected = reducer.reduce(canonical, [
      mutation(3, MutationOperation.update, {'note': 'Later'}),
      mutation(2, MutationOperation.update, {'name': 'After'}),
    ]);

    expect(projected?.fields, {'name': 'After', 'note': 'Later'});
    expect(
      () => projected?.fields['name'] = 'mutation',
      throwsUnsupportedError,
    );
    expect(canonical.fields['name'], 'Before');
  });

  test('keeps create and delete rows while projecting absence', () {
    expect(
      reducer.reduce(null, [
        mutation(1, MutationOperation.create, {'name': 'Temporary'}),
        mutation(2, MutationOperation.delete),
      ]),
      isNull,
    );
  });

  ModelMutation<TestId> inheritedDelete(int ordinal) => ModelMutation(
    position: MutationPosition(mutationOrdinal: ordinal, operationPosition: 0),
    id: id,
    operation: MutationOperation.delete,
    values: const {},
    inherited: true,
  );

  test('an inherited delete takes out a row that is there', () {
    expect(
      reducer.reduce(
        ModelRecord(id: id, fields: const {'name': 'Page', 'note': null}),
        [inheritedDelete(1)],
      ),
      isNull,
    );
  });

  test('an inherited delete is absorbed by a row that is already gone', () {
    // The user deleted the page themselves, then burned the book: replaying
    // the book's delete over the already-absent page must be a no-op, not the
    // integrity failure a user's own delete-of-absent is.
    expect(
      reducer.reduce(
        ModelRecord(id: id, fields: const {'name': 'Page', 'note': null}),
        [mutation(1, MutationOperation.delete), inheritedDelete(2)],
      ),
      isNull,
    );
    expect(reducer.reduce(null, [inheritedDelete(1)]), isNull);
  });

  test('a row created after an inherited delete stands', () {
    expect(
      reducer.reduce(null, [
        inheritedDelete(1),
        mutation(2, MutationOperation.create, {'name': 'Fresh'}),
      ]),
      ModelRecord(id: id, fields: const {'name': 'Fresh', 'note': null}),
    );
  });

  for (final invalid
      in <
        ({
          String name,
          ModelRecord<TestId>? canonical,
          List<ModelMutation<TestId>> mutations,
        })
      >[
        (
          name: 'update absent',
          canonical: null,
          mutations: [
            mutation(1, MutationOperation.update, {'name': 'No'}),
          ],
        ),
        (
          name: 'delete absent',
          canonical: null,
          mutations: [mutation(1, MutationOperation.delete)],
        ),
        (
          name: 'create present',
          canonical: ModelRecord(
            id: id,
            fields: const {'name': 'Yes', 'note': null},
          ),
          mutations: [
            mutation(1, MutationOperation.create, {'name': 'No'}),
          ],
        ),
        (
          name: 'mutation after delete',
          canonical: ModelRecord(
            id: id,
            fields: const {'name': 'Yes', 'note': null},
          ),
          mutations: [
            mutation(1, MutationOperation.delete),
            mutation(2, MutationOperation.update, {'name': 'No'}),
          ],
        ),
        (
          name: 'missing required create field',
          canonical: null,
          mutations: [mutation(1, MutationOperation.create)],
        ),
        (
          name: 'empty update',
          canonical: ModelRecord(
            id: id,
            fields: const {'name': 'Yes', 'note': null},
          ),
          mutations: [mutation(1, MutationOperation.update)],
        ),
        (
          name: 'delete values',
          canonical: ModelRecord(
            id: id,
            fields: const {'name': 'Yes', 'note': null},
          ),
          mutations: [
            mutation(1, MutationOperation.delete, {'name': 'No'}),
          ],
        ),
        (
          name: 'identity in values',
          canonical: null,
          mutations: [
            mutation(1, MutationOperation.create, {
              'id': id.value,
              'name': 'No',
            }),
          ],
        ),
        (
          name: 'duplicate ordinal',
          canonical: null,
          mutations: [
            mutation(1, MutationOperation.create, {'name': 'One'}),
            mutation(1, MutationOperation.update, {'name': 'Two'}),
          ],
        ),
      ]) {
    test('rejects ${invalid.name}', () {
      expect(
        () => reducer.reduce(invalid.canonical, invalid.mutations),
        throwsA(isA<ProjectionIntegrityException>()),
      );
    });
  }
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
