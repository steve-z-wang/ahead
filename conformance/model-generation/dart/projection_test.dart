import 'package:local_sync/local_sync.dart';
import 'package:local_sync_conformance/src/generated/enums.dart';
import 'package:local_sync_conformance/src/generated/models/moment.dart';
import 'package:local_sync_conformance/src/generated/models/space.dart';
import 'package:local_sync_conformance/src/generated/models/star.dart';
import 'package:local_sync_conformance/src/generated/models/user.dart';
import 'package:local_sync_conformance/src/generated/storage/moment.dart';
import 'package:local_sync_conformance/src/generated/storage/space.dart';
import 'package:local_sync_conformance/src/generated/storage/star.dart';
import 'package:local_sync_conformance/src/generated/storage/user.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late TestDatabase fixture;
  late Database database;
  late LocalDatabaseScope scope;
  late SqlCanonicalStore<UserId> users;
  late SqlCanonicalStore<SpaceId> spaces;
  late SqlCanonicalStore<MomentId> moments;
  late SqlCanonicalStore<StarId> stars;

  setUp(() async {
    fixture = await TestDatabase.create();
    database = await fixture.driver.open();
    scope = LocalDatabaseScope(database);
    users = SqlCanonicalStore(
      database: scope,
      descriptor: userDatabaseDescriptor,
    );
    spaces = SqlCanonicalStore(
      database: scope,
      descriptor: spaceDatabaseDescriptor,
    );
    moments = SqlCanonicalStore(
      database: scope,
      descriptor: momentDatabaseDescriptor,
    );
    stars = SqlCanonicalStore(
      database: scope,
      descriptor: starDatabaseDescriptor,
    );
  });

  tearDown(() async {
    await database.close();
    await fixture.dispose();
  });

  test(
    'generated bindings address scalar and composite canonical rows',
    () async {
      final userId = UserId(uuid(1));
      final momentId = MomentId(uuid(2));
      final spaceId = SpaceId(uuid(3));
      final starId = StarId(userId: userId.value, momentId: momentId.value);

      await users.create(userId, {'handle': 'steve'});
      await spaces.create(spaceId, {
        'ownerId': userId.value,
        'name': 'Family',
        'kind': SpaceKind.group,
      });
      await moments.create(momentId, {
        'spaceId': spaceId.value,
        'capturedAt': DateTime.utc(2026, 8, 3),
        'caption': null,
      });
      await stars.create(starId, const {});

      expect((await stars.get(starId))?.id, starId);
      await spaces.upsert(spaceId, {
        'ownerId': userId.value,
        'name': 'Replacement',
        'kind': SpaceKind.group,
      });
      expect((await spaces.get(spaceId))?.fields['name'], 'Replacement');
      expect(await moments.get(momentId), isNotNull);
      await spaces.update(spaceId, {'name': 'Home'});
      expect((await spaces.get(spaceId))?.fields['name'], 'Home');
      await stars.delete(starId);
      expect(await stars.get(starId), isNull);
      await stars.purge(starId);
      await spaces.delete(spaceId);
      // CAP-393 spec §6.1: a Cascade relation carries no constraint, so the
      // page outlives the book it belonged to until the Backend claims its
      // death (CAP-396). Nothing disappears without a claim behind it.
      expect(await moments.get(momentId), isNotNull);
    },
  );

  // CAP-393: the main tables ARE the merged view, so there is no projection
  // left to fold. What the before-image buys is that the optimistic row is
  // the one every reader sees — typed or raw SQL — while the server's truth
  // waits beside it.
  test('an optimistic edit is the row itself, with truth held aside', () async {
    final userId = UserId(uuid(1));
    final spaceId = SpaceId(uuid(2));
    await users.create(userId, {'handle': 'steve'});
    await spaces.create(spaceId, {
      'ownerId': userId.value,
      'name': 'Family',
      'kind': SpaceKind.group,
    });

    final spaceBefore = BeforeImageStore<SpaceId>(
      database: scope,
      main: spaceDatabaseDescriptor,
      before: spaceBeforeDatabaseDescriptor,
    );
    final writer = ModelMutationWriter<SpaceId>(
      SqlMutationStore(database: scope, schema: spaceSchema),
      before: spaceBefore,
      main: spaces,
    );

    // A synced write is a letter of some named act, so the record comes first
    // and every operation below names it (CAP-444).
    final act = await _openAct(scope, 'RenameSpace');

    await writer.update(
      spaceId,
      {'name': 'Projected'},
      mutationOrdinal: act,
      wire: true,
    );
    expect((await spaces.get(spaceId))?.fields['name'], 'Projected');
    expect((await spaceBefore.read(spaceId))?.fields['name'], 'Family');

    // Raw SQL sees exactly what the typed reader sees — the whole point of
    // materializing the merged view.
    final raw = await database.query(
      DatabaseQuery(sql: 'SELECT name FROM model_space'),
    );
    expect(raw.rows.single['name'], 'Projected');

    await writer.delete(
      spaceId,
      mutationOrdinal: await _openAct(scope, 'DeleteSpace'),
      wire: true,
    );
    expect(await spaces.get(spaceId), isNull);
    expect((await spaceBefore.read(spaceId))?.fields['name'], 'Family');
  });
}

/// Queues one named record and hands back its ordinal — what `mutate` does
/// before it applies a single operation.
Future<int> _openAct(LocalDatabaseScope scope, String name) async {
  final result = await scope.current.execute(
    DatabaseStatement(
      sql: 'INSERT INTO pending_mutations (name) VALUES (?)',
      variables: [name],
    ),
  );
  return result.lastInsertRowId!;
}

UUID uuid(int value) => UUID.withValidation(
  '550e8400-e29b-41d4-a716-${value.toString().padLeft(12, '0')}',
);
