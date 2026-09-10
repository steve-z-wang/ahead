import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:local_sync/local_sync.dart';
import 'package:local_sync_conformance/local_sync_conformance.dart';
import 'package:test/test.dart';

import 'support.dart';

/// A row whose prerequisite is pending holds its whole act back until the
/// Engine-driven handler finishes, and then the act ships as one wire element.
///
/// `StarTag.label` is the readiness key and `CaptureMoment` is the act that
/// carries a page, its tags and the star that keeps it — so which writes share
/// fate is the schema's word, not a walk over the reference graph (CAP-439).
void main() {
  test('a group waits for its key, then ships in one batch', () async {
    final database = await TestDatabase.create();
    addTearDown(database.dispose);
    final transport = GateTransport();
    final prerequisites = ControlledPrerequisites();
    final localSync = await LocalSync.open(
      driver: database.driver,
      clientId: testClientId,
      transport: transport,
      prerequisites: prerequisites.handlers,
    );
    await activateTestScopes(localSync);
    addTearDown(localSync.close);

    final userId = UserId(uuid(1));
    final momentId = MomentId(uuid(2));
    final spaceId = SpaceId(uuid(3));
    final starId = StarId(userId: userId.value, momentId: momentId.value);
    final firstTagId = StarTagId(uuid(6));
    final secondTagId = StarTagId(uuid(7));

    // Everything the page hangs off is already synced, so the only thing left
    // to wait for is the key itself.
    await localSync.transaction(
      (outerTx) => outerTx.mutate.registerUser(
        (tx) async => (user: User.create(id: userId.value, handle: 'steve')),
      ),
    );
    await localSync.transaction(
      (outerTx) => outerTx.mutate.createSpace(
        (tx) async => (
          space: Space.create(
            id: spaceId.value,
            ownerId: userId.value,
            name: 'Family',
            kind: SpaceKind.group,
            avatarKey: null,
          ),
        ),
      ),
    );
    await pumpUntilQueueIs(localSync, transport, 0);

    // Written offline, as one act: the page, both of its tags, and the star.
    await localSync.transaction(
      (outerTx) => outerTx.mutate.captureMoment(
        (tx) async => _capture(
          userId: userId,
          momentId: momentId,
          spaceId: spaceId,
          labels: {firstTagId: 'holiday', secondTagId: 'holiday'},
        ),
      ),
    );

    final sentBefore = transport.bodies.length;
    await settle();

    // Nothing ships — not even the star, which carries no key of its own.
    expect(transport.bodies.length, sentBefore);
    expect(await pendingMutationCount(localSync), 1);

    prerequisites.complete('holiday', PrerequisiteAttemptResult.ready);
    await pumpUntilQueueIs(localSync, transport, 0);

    // One batch, and one wire element in it: four operations travelled as the
    // single act they were declared to be, and the whole is never published
    // without its parts.
    expect(transport.bodies.length, sentBefore + 1);
    expect(transport.batchSizes.last, 1);
    expect(transport.operationCounts.last, [4]);

    // Fully synced means every auxiliary table is empty — the ledger row was
    // pruned when the last mutation referencing it settled, and no row is left
    // holding truth aside.
    await expectEmptyReadiness(localSync);
    expect(await localSync.models.moment.get(momentId), isNotNull);
    expect(await localSync.models.starTag.get(firstTagId), isNotNull);
    expect(await localSync.models.starTag.get(secondTagId), isNotNull);
    expect(await localSync.models.star.get(starId), isNotNull);
  });

  // CAP-627: a failed prerequisite parks the complete named act. Explicit
  // Discard keeps CAP-444 whole-act rollback while unrelated work ships.
  test('a failed key parks its act while unrelated work ships', () async {
    final database = await TestDatabase.create();
    addTearDown(database.dispose);
    final transport = GateTransport();
    final prerequisites = ControlledPrerequisites();
    final localSync = await LocalSync.open(
      driver: database.driver,
      clientId: testClientId,
      transport: transport,
      prerequisites: prerequisites.handlers,
    );
    await activateTestScopes(localSync);
    addTearDown(localSync.close);

    final userId = UserId(uuid(1));
    final momentId = MomentId(uuid(2));
    final spaceId = SpaceId(uuid(3));
    final starId = StarId(userId: userId.value, momentId: momentId.value);
    final goodTagId = StarTagId(uuid(6));
    final doomedTagId = StarTagId(uuid(7));

    await localSync.transaction(
      (outerTx) => outerTx.mutate.registerUser(
        (tx) async => (user: User.create(id: userId.value, handle: 'steve')),
      ),
    );
    await localSync.transaction(
      (outerTx) => outerTx.mutate.createSpace(
        (tx) async => (
          space: Space.create(
            id: spaceId.value,
            ownerId: userId.value,
            name: 'Family',
            kind: SpaceKind.group,
            avatarKey: null,
          ),
        ),
      ),
    );
    await pumpUntilQueueIs(localSync, transport, 0);

    await localSync.transaction(
      (outerTx) => outerTx.mutate.captureMoment(
        (tx) async => _capture(
          userId: userId,
          momentId: momentId,
          spaceId: spaceId,
          labels: {goodTagId: 'kept', doomedTagId: 'lost'},
        ),
      ),
    );
    // Queued behind the doomed act, and no business of its own: the queue is
    // never taken down with the act that dies.
    await localSync.transaction(
      (outerTx) => outerTx.mutate.renameSpace(
        (tx) async => (
          space: tx.space.update(
            (await tx.models.space.get(spaceId))!,
            name: 'Renamed',
          ),
        ),
      ),
    );

    prerequisites.complete('kept', PrerequisiteAttemptResult.ready);
    prerequisites.complete('lost', PrerequisiteAttemptResult.failed);
    final failures = await localSync.prerequisites.watchFailures().firstWhere(
      (items) => items.isNotEmpty,
    );
    await pumpUntilQueueIs(localSync, transport, 1);
    expect(failures, hasLength(1));
    expect(await localSync.models.moment.get(momentId), isNotNull);
    expect(await localSync.models.star.get(starId), isNotNull);
    expect(await localSync.models.starTag.get(goodTagId), isNotNull);
    expect(await localSync.models.starTag.get(doomedTagId), isNotNull);
    expect(transport.sentActs, contains('RenameSpace'));
    await localSync.prerequisites.discard(failures.single.id);
    await pumpUntilQueueIs(localSync, transport, 0);

    // The doomed act is gone whole — the page and the star it was declared
    // with, not only the tag whose key failed.
    expect(await localSync.models.moment.get(momentId), isNull);
    expect(await localSync.models.star.get(starId), isNull);
    expect(await localSync.models.starTag.get(goodTagId), isNull);
    expect(await localSync.models.starTag.get(doomedTagId), isNull);
    // Nothing of it was ever published, and the act behind it went on its way
    // regardless: the queue is never taken down with the act that dies.
    expect(transport.sentActs, isNot(contains('CaptureMoment')));
    expect(transport.sentActs, contains('RenameSpace'));
    await expectEmptyReadiness(localSync);
  });

  // CAP-521: readiness belongs to a KEY, not a mutation. Two acts may wait on
  // the same key — a clip uploading once while two pages carry it — and the
  // one that dies must not take the mark the survivor is still gated on.
  test('discarding a parked act preserves the shared-key survivor', () async {
    final database = await TestDatabase.create();
    addTearDown(database.dispose);
    final transport = GateTransport();
    final prerequisites = ControlledPrerequisites();
    final localSync = await LocalSync.open(
      driver: database.driver,
      clientId: testClientId,
      transport: transport,
      prerequisites: prerequisites.handlers,
    );
    await activateTestScopes(localSync);
    addTearDown(localSync.close);

    final userId = UserId(uuid(1));
    final momentId = MomentId(uuid(2));
    final doomedMomentId = MomentId(uuid(4));
    final spaceId = SpaceId(uuid(3));
    final sharedTagId = StarTagId(uuid(6));
    final doomedSharedTagId = StarTagId(uuid(7));
    final doomedTagId = StarTagId(uuid(8));

    await localSync.transaction(
      (outerTx) => outerTx.mutate.registerUser(
        (tx) async => (user: User.create(id: userId.value, handle: 'steve')),
      ),
    );
    await localSync.transaction(
      (outerTx) => outerTx.mutate.createSpace(
        (tx) async => (
          space: Space.create(
            id: spaceId.value,
            ownerId: userId.value,
            name: 'Family',
            kind: SpaceKind.group,
            avatarKey: null,
          ),
        ),
      ),
    );
    await pumpUntilQueueIs(localSync, transport, 0);

    // The surviving act carries only the shared key.
    await localSync.transaction(
      (outerTx) => outerTx.mutate.captureMoment(
        (tx) async => _capture(
          userId: userId,
          momentId: momentId,
          spaceId: spaceId,
          labels: {sharedTagId: 'shared'},
        ),
      ),
    );
    // The doomed act carries the SAME shared key plus its own failed one.
    await localSync.transaction(
      (outerTx) => outerTx.mutate.captureMoment(
        (tx) async => _capture(
          userId: userId,
          momentId: doomedMomentId,
          spaceId: spaceId,
          labels: {doomedSharedTagId: 'shared', doomedTagId: 'lost'},
        ),
      ),
    );

    prerequisites.complete('shared', PrerequisiteAttemptResult.ready);
    prerequisites.complete('lost', PrerequisiteAttemptResult.failed);
    final failures = await localSync.prerequisites.watchFailures().firstWhere(
      (items) => items.isNotEmpty,
    );
    await pumpUntilQueueIs(localSync, transport, 1);
    expect(failures, hasLength(1));
    await localSync.prerequisites.discard(failures.single.id);
    await pumpUntilQueueIs(localSync, transport, 0);

    // The doomed act is gone; the survivor shipped on the one mark it was
    // ever given — dropping the neighbour did not strand it.
    expect(await localSync.models.moment.get(momentId), isNotNull);
    expect(await localSync.models.moment.get(doomedMomentId), isNull);
    await expectEmptyReadiness(localSync);
  });

  // CAP-513: a nullable readiness field gates only while it carries a string.
  // Null is not a key — the act ships at once, marks nothing, and leaves no
  // ledger row; the same field holding a string gates like any required key.
  test('a null optional key holds nothing back', () async {
    final database = await TestDatabase.create();
    addTearDown(database.dispose);
    final transport = GateTransport();
    final prerequisites = ControlledPrerequisites();
    final localSync = await LocalSync.open(
      driver: database.driver,
      clientId: testClientId,
      transport: transport,
      prerequisites: prerequisites.handlers,
    );
    await activateTestScopes(localSync);
    addTearDown(localSync.close);

    final userId = UserId(uuid(1));
    final spaceId = SpaceId(uuid(3));

    // The null key act drains with no mark ever given, and no ledger row is
    // left behind: null was never a key at all.
    await localSync.transaction(
      (outerTx) => outerTx.mutate.registerUser(
        (tx) async => (user: User.create(id: userId.value, handle: 'steve')),
      ),
    );
    await localSync.transaction(
      (outerTx) => outerTx.mutate.createSpace(
        (tx) async => (
          space: Space.create(
            id: spaceId.value,
            ownerId: userId.value,
            name: 'Family',
            kind: SpaceKind.group,
            avatarKey: null,
          ),
        ),
      ),
    );
    await pumpUntilQueueIs(localSync, transport, 0);
    await expectEmptyReadiness(localSync);

    // The same field carrying a string gates like any required key.
    await localSync.transaction(
      (outerTx) => outerTx.mutate.renameSpace(
        (tx) async => (
          space: tx.space.update(
            (await tx.models.space.get(spaceId))!,
            avatarKey: const FieldUpdate.set('cover-key'),
          ),
        ),
      ),
    );
    await settle();
    expect(await pendingMutationCount(localSync), 1);
    expect((await localSync.models.space.get(spaceId))!.avatarKey, 'cover-key');

    prerequisites.complete('cover-key', PrerequisiteAttemptResult.ready);
    await pumpUntilQueueIs(localSync, transport, 0);
    await expectEmptyReadiness(localSync);
  });
}

/// The act under test: one page, its tags, and the star that keeps it.
CaptureMomentResult _capture({
  required UserId userId,
  required MomentId momentId,
  required SpaceId spaceId,
  required Map<StarTagId, String> labels,
}) => (
  moment: Moment.create(
    id: momentId.value,
    spaceId: spaceId.value,
    capturedAt: DateTime.utc(2026, 8, 7),
    caption: null,
  ),
  tags: [
    for (final entry in labels.entries)
      StarTag.create(
        id: entry.key.value,
        userId: userId.value,
        momentId: momentId.value,
        label: entry.value,
      ),
  ],
  star: Star.create(userId: userId.value, momentId: momentId.value),
);

/// Accepts every batch and then hands the client a page, so the batch settles
/// the way a real round trip settles it. Without that second half nothing ever
/// leaves the queue, and one in-flight batch would block the gate forever.
final class GateTransport implements LocalSyncTransport {
  final bodies = <Uint8List>[];
  final _events = StreamController<DownlinkTransportEvent>.broadcast();

  /// The server's log head. Every accepted batch advances it, which is what
  /// lets the page that follows settle the batch.
  int _head = 0;
  int _delivered = 0;

  /// How many named acts each sent batch carried, in order.
  List<int> get batchSizes => [for (final body in bodies) _acts(body).length];

  /// How many operations each act of each sent batch carried, in order.
  List<List<int>> get operationCounts => [
    for (final body in bodies)
      [
        for (final act in _acts(body))
          ((act as Map)['operations']! as List).length,
      ],
  ];

  /// Every act that reached the wire, by name and in order.
  List<String> get sentActs => [
    for (final body in bodies)
      for (final act in _acts(body)) (act as Map)['name']! as String,
  ];

  List<Object?> _acts(Uint8List body) =>
      (jsonDecode(utf8.decode(body)) as Map)['mutations']! as List;

  @override
  Stream<DownlinkTransportEvent> get downlinkEvents => _events.stream;

  @override
  Future<void> start() async {
    if (!_events.isClosed) _events.add(const DownlinkConnected());
  }

  @override
  Future<void> sendDownlinkFrame(Uint8List frame) async {
    final request = jsonDecode(utf8.decode(frame)) as Map;
    _events.add(
      DownlinkPageReceived(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'type': 'subscribed',
              'scopes': request['scopes'],
              'rejections': <Object?>[],
            }),
          ),
        ),
      ),
    );
  }

  @override
  Future<void> restartDownlinkConnection() => start();

  @override
  Future<LocalSyncHttpResponse> sendUplink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  }) async {
    bodies.add(body);
    _head += 1;
    return LocalSyncHttpResponse(
      statusCode: 200,
      body: uplinkResponseBytes(_head),
    );
  }

  @override
  Future<LocalSyncHttpResponse> fetchDownlink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  }) async => LocalSyncHttpResponse(
    statusCode: 200,
    body: emptyPageBytes(afterSyncIdOf(body), scope: scopeOf(body)),
  );

  /// Hands the client the page that settles whatever it has just sent.
  ///
  /// A batch settles only once the Downlink cursor moves PAST the sync id the
  /// response required, so the page has to carry the head forward.
  void acknowledge() {
    if (_events.isClosed || _head == _delivered) return;
    _events.add(
      DownlinkPageReceived(
        pageBytes(
          fromSyncId: _delivered,
          throughSyncId: _head,
          changes: const <Map<String, Object?>>[],
        ),
      ),
    );
    _delivered = _head;
  }

  @override
  Future<void> close() async {
    if (!_events.isClosed) await _events.close();
  }
}

/// Lets the workers run until the queue reaches [expected], or gives up.
///
/// A batch settles on the client only when a Downlink page carries the cursor
/// past it, so the round trip is driven here rather than waited on.
Future<void> pumpUntilQueueIs(
  LocalSync localSync,
  GateTransport transport,
  int expected,
) async {
  for (var attempt = 0; attempt < 200; attempt += 1) {
    if (await pendingMutationCount(localSync) == expected) return;
    transport.acknowledge();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(await pendingMutationCount(localSync), expected);
}

/// Lets the workers run when nothing is expected to change.
Future<void> settle() =>
    Future<void>.delayed(const Duration(milliseconds: 200));

Future<int> pendingMutationCount(LocalSync localSync) async =>
    (await localSync.readOnlySql.query(
      'SELECT ordinal FROM pending_mutations',
    )).length;

UUID uuid(int value) => UUID.withValidation(
  '550e8400-e29b-41d4-a716-${value.toString().padLeft(12, '0')}',
);

Future<void> expectEmptyReadiness(LocalSync localSync) async {
  final result = await localSync.readOnlySql.query(
    'SELECT COUNT(*) AS count FROM readiness_states',
  );
  expect(result[0]['count'], 0);
}
