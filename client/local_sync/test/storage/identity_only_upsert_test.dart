import 'package:local_sync/local_sync.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:test/test.dart';

import '../support/test_database.dart';

/// A Model that is nothing but its identity — a pure association, like a star
/// keyed `(userId, momentId)`.
///
/// Its presence IS its state, so an upsert of a row that already exists has
/// nothing to assign. `DO UPDATE SET` with no assignment is not SQL, and the
/// Downlink apply path is where that reaches a database.
final class PairId extends ModelId {
  const PairId({required this.userId, required this.momentId});

  final UUID userId;
  final UUID momentId;

  @override
  Map<String, Object> get components => {
    'userId': userId,
    'momentId': momentId,
  };

  @override
  bool operator ==(Object other) =>
      other is PairId && other.userId == userId && other.momentId == momentId;

  @override
  int get hashCode => Object.hash(userId, momentId);
}

void main() {
  final schema = ModelSchema<PairId>(
    name: 'Pair',
    identity: const ['userId', 'momentId'],
    fields: const [
      ModelFieldSchema(
        name: 'userId',
        type: LocalScalarType.uuid,
        nullable: false,
      ),
      ModelFieldSchema(
        name: 'momentId',
        type: LocalScalarType.uuid,
        nullable: false,
      ),
    ],
    uniqueConstraints: const [],
    relations: const [],
    createId: (components) => PairId(
      userId: components['userId']! as UUID,
      momentId: components['momentId']! as UUID,
    ),
  );

  final descriptor = ModelDatabaseDescriptor<PairId>(
    schema: schema,
    tableName: 'model_pair',
    columns: const {'userId': 'user_id', 'momentId': 'moment_id'},
  );

  final id = PairId(
    userId: UUID.withValidation('550e8400-e29b-41d4-a716-446655440000'),
    momentId: UUID.withValidation('550e8400-e29b-41d4-a716-446655440001'),
  );

  late TestLocalDatabase fixture;
  late SqlCanonicalStore<PairId> store;

  setUp(() async {
    fixture = await TestLocalDatabase.open(
      modelStatements: [
        DatabaseStatement(
          sql: '''
            CREATE TABLE "model_pair" (
              "user_id" TEXT NOT NULL,
              "moment_id" TEXT NOT NULL,
              PRIMARY KEY ("user_id", "moment_id")
            )
          ''',
        ),
      ],
    );
    store = SqlCanonicalStore<PairId>(
      database: fixture.scope,
      descriptor: descriptor,
    );
  });

  tearDown(() => fixture.close());

  test('upserts a Model that is nothing but its identity', () async {
    await store.upsert(id, const {});
    // Again: the row exists, and the server says it exists. There is nothing
    // to assign, and saying so must not be a syntax error.
    await store.upsert(id, const {});

    expect(await store.get(id), isNotNull);
    final count = await fixture.scope.current.query(
      DatabaseQuery(sql: 'SELECT COUNT(*) AS count FROM "model_pair"'),
    );
    expect(count.rows.single['count'], 1);
  });
}
