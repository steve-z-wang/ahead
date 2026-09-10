import 'dart:convert';

import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

import '../support/cascade_family.dart';
import '../support/test_database.dart';

/// The wire shape of a named act (CAP-439): one record, one element, its
/// operations inside it in slot order.
void main() {
  const clientId = '5d6c1f20-9105-4f7e-89d7-163fa5dcbb84';
  late TestLocalDatabase fixture;
  late FamilyRegistry family;
  late FamilyRuntimes runtimes;
  late MutationQueue outbox;
  late LocalSyncJsonCodec codec;
  late ReadinessLedger ledger;

  final spaceId = FamilySpaceId(familyUuid(1));
  final momentId = FamilyMomentId(familyUuid(2));

  setUp(() async {
    fixture = await TestLocalDatabase.open(
      modelStatements: familyModelStatements,
    );
    family = FamilyRegistry(fixture.scope);
    runtimes = FamilyRuntimes(fixture.scope, family.registry);
    outbox = MutationQueue(fixture.scope, registry: family.registry);
    await outbox.initialize(clientId);
    codec = LocalSyncJsonCodec(registry: family.registry);
    ledger = ReadinessLedger(fixture.scope);
    await family.space.create(spaceId, {'name': 'book'});
  });

  tearDown(() => fixture.close());

  Future<Map<String, Object?>> encodeQueue() async {
    final candidate = await outbox.scheduledCandidate(limit: 20);
    return jsonDecode(
          utf8.decode(
            codec.encodeUplinkRequest(
              clientId: candidate!.clientId,
              batchSequence: candidate.batchSequence,
              mutations: candidate.mutations,
              records: candidate.records,
            ),
          ),
        )
        as Map<String, Object?>;
  }

  test('a companion is queued but never encoded', () async {
    // Two operations on one Model inside one act: the companion was written
    // through the callback's `tx`, the wire slot was returned. Only the
    // returned one reaches the body, and the element's ordinal is that one's
    // (CAP-488).
    await runtimes.apply(
      familyMutationRecord(
        name: 'CaptionWithNote',
        operations: [
          ModelCreateOperation(
            model: 'FamilyMoment',
            id: momentId,
            values: {'spaceId': spaceId.value, 'caption': 'a page'},
          ),
        ],
      ),
      companions: (models) => models.tag.create(FamilyTagId(familyUuid(70)), {
        'momentId': momentId.value,
      }),
    );

    final stored = await outbox.scheduledCandidate(limit: 20);
    expect(stored!.mutations.map((row) => (row.model, row.isUplink)), [
      ('FamilyTag', false),
      ('FamilyMoment', true),
    ]);

    final request = await encodeQueue();
    final elements = request['mutations']! as List<Object?>;
    final element = elements.single! as Map<String, Object?>;
    final operations = element['operations']! as List<Object?>;
    expect(operations, hasLength(1));
    expect(
      (operations.single! as Map<String, Object?>)['model'],
      'FamilyMoment',
    );
    // The parent owns the wire ordinal, so every response names the act rather
    // than one of its operations.
    expect(element['ordinal'], stored.records.keys.single);
    expect(element['version'], 1);
  });

  test('a named act encodes as one element carrying its operations', () async {
    await runtimes.apply(
      familyMutationRecord(
        name: 'CapturePage',
        operations: [
          ModelCreateOperation(
            model: 'FamilyMoment',
            id: momentId,
            values: {'spaceId': spaceId.value, 'caption': 'a page'},
          ),
          ModelCreateOperation(
            model: 'FamilyPhoto',
            id: FamilyPhotoId(familyUuid(10)),
            values: {'momentId': momentId.value, 'key': 'one'},
          ),
          ModelCreateOperation(
            model: 'FamilyPhoto',
            id: FamilyPhotoId(familyUuid(11)),
            values: {'momentId': momentId.value, 'key': 'two'},
          ),
        ],
      ),
    );

    await ledger.markReady(remoteObject('one'));
    await ledger.markReady(remoteObject('two'));

    final request = await encodeQueue();
    final elements = request['mutations']! as List<Object?>;
    expect(elements, hasLength(1));

    final element = elements.single! as Map<String, Object?>;
    expect(element['name'], 'CapturePage');
    // The wire ordinal is the act's, taken from its first operation, so a
    // rejection names something the client can find.
    expect(element['ordinal'], 1);

    final operations = element['operations']! as List<Object?>;
    expect(operations, hasLength(3));
    expect(
      operations.cast<Map<String, Object?>>().map(
        (operation) => operation['model'],
      ),
      ['FamilyMoment', 'FamilyPhoto', 'FamilyPhoto'],
    );
    // An operation inside an act is addressed but not positioned: the act
    // holds the position, and slot order holds the rest.
    expect(
      operations.cast<Map<String, Object?>>().every(
        (operation) => !operation.containsKey('ordinal'),
      ),
      isTrue,
    );
    expect((operations.first! as Map<String, Object?>)['op'], 'create');
  });

  test('a 42-operation act is one element in the batch', () async {
    await runtimes.apply(
      familyMutationRecord(
        name: 'CapturePage',
        operations: [
          ModelCreateOperation(
            model: 'FamilyMoment',
            id: momentId,
            values: {'spaceId': spaceId.value, 'caption': 'a page'},
          ),
          for (var index = 0; index < 41; index += 1)
            ModelCreateOperation(
              model: 'FamilyPhoto',
              id: FamilyPhotoId(familyUuid(100 + index)),
              values: {'momentId': momentId.value, 'key': 'photo-$index'},
            ),
        ],
      ),
    );

    for (var index = 0; index < 41; index += 1) {
      await ledger.markReady(remoteObject('photo-$index'));
    }

    final request = await encodeQueue();
    final elements = request['mutations']! as List<Object?>;
    expect(elements, hasLength(1));
    expect(
      (elements.single! as Map<String, Object?>)['operations'],
      hasLength(42),
    );
  });

  test('the batch ceiling counts acts, and refuses a 21st', () async {
    final rows = <StoredMutationOperation>[];
    final records = <int, StoredMutation>{};
    for (var index = 0; index < 21; index += 1) {
      records[index + 1] = StoredMutation(
        ordinal: index + 1,
        name: 'CapturePage',
        legacyFifo: false,
      );
      rows.add(
        StoredMutationOperation(
          mutationOrdinal: index + 1,
          position: 0,
          model: 'FamilyMoment',
          identityJson: jsonEncode({'id': familyUuid(index + 2).toString()}),
          operation: 'delete',
          valuesJson: '{}',
          isUplink: true,
        ),
      );
    }

    expect(
      () => codec.encodeUplinkRequest(
        clientId: clientId,
        batchSequence: 1,
        mutations: rows,
        records: records,
      ),
      throwsA(isA<UplinkDataException>()),
    );
  });

  test('refuses to encode an act whose record is missing', () async {
    expect(
      () => codec.encodeUplinkRequest(
        clientId: clientId,
        batchSequence: 1,
        mutations: [
          StoredMutationOperation(
            mutationOrdinal: 7,
            position: 0,
            model: 'FamilyMoment',
            identityJson: jsonEncode({'id': momentId.value.toString()}),
            operation: 'delete',
            valuesJson: '{}',
            isUplink: true,
          ),
        ],
        records: const {},
      ),
      throwsA(isA<UplinkDataException>()),
    );
  });
}
