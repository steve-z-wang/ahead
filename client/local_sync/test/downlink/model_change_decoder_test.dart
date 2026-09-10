import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

import '../support/never_registry_entry.dart';
import '../support/wire_models.dart';

void main() {
  final registry = ModelRegistry([
    NeverModelRegistryEntry(spaceSchema),
    NeverModelRegistryEntry(starSchema),
  ]);
  final decoder = ModelChangeDecoder(registry);

  test('decodes an exact full-state upsert', () {
    final change = decoder.decode(address(spaceUpsert()));

    expect(change.syncId, 101);
    expect(change.entry, same(registry['Space']));
    expect(change.operation, DownlinkOperation.upsert);
    expect(change.id, SpaceId(uuid(spaceId)));
    expect(change.values, {
      'ownerId': uuid(ownerId),
      'name': 'Family',
      'isOpen': true,
      'memberCount': 3,
      'ratio': 1.5,
      'kind': TestSpaceKind.group,
      'spaceOrder': [uuid(spaceId)],
      'rankOrder': [1, 2],
      'eventTimes': [DateTime.utc(2026, 8, 3, 19)],
      'archivedAt': null,
    });
  });

  // The framework's published evolution rule is additive: a field that has
  // once been generated "may gain company and may never leave"
  // (conformance/model-generation/.../schema-evolution.spec.ts). The decoder
  // used to contradict it — an exact key-set match, so ONE extra key refused
  // the row. And a refused row is skipped past forever, because the Downlink
  // cursor advances over it.
  //
  // So adding a nullable field to a Model deleted that Model's rows from every
  // build already in the field. It happened: CAP-457 added `Space.description`
  // and older builds lost their books while keeping the entries inside them.
  test('ignores a field the client has never heard of', () {
    final change = decoder.decode(
      address({
        ...spaceUpsert(),
        'data': {...spaceData(), 'colour': 'blue'},
      }),
    );

    expect(change.values.containsKey('colour'), isFalse);
    // Everything it does know survives intact.
    expect(change.values['name'], spaceData()['name']);
  });

  // The same tolerance runs the other way: a NEWER client against an older
  // server is missing the fields it just learned, and a nullable field that
  // was never sent is simply null. (A missing required field still throws —
  // tolerance is for keys the client does not know or need, never for keys
  // it needs and did not get.)
  test('a nullable field the server never sent decodes as null', () {
    final data = spaceData()..remove('archivedAt');
    final change = decoder.decode(address({...spaceUpsert(), 'data': data}));

    expect(change.values.containsKey('archivedAt'), isTrue);
    expect(change.values['archivedAt'], isNull);
  });

  test('a newer server may add several at once', () {
    final change = decoder.decode(
      address({
        ...spaceUpsert(),
        'data': {...spaceData(), 'colour': 'blue', 'weight': 3, 'seen': true},
      }),
    );

    expect(change.values['name'], spaceData()['name']);
  });

  test('decodes an exact composite delete identity', () {
    final change = decoder.decode(
      AddressedModelChange(
        syncId: 102,
        raw: {
          'syncId': 102,
          'model': 'Star',
          'operation': 'delete',
          'id': {'userId': ownerId, 'momentId': momentId},
        },
      ),
    );

    expect(change.operation, DownlinkOperation.delete);
    expect(change.id, StarId(uuid(ownerId), uuid(momentId)));
    expect(change.values, isEmpty);
  });

  for (final (label, raw) in <(String, Map<String, Object?>)>[
    ('an extra change key', {...spaceUpsert(), 'kind': 'model'}),
    ('a mismatched address', {...spaceUpsert(), 'syncId': 102}),
    ('an unknown Model', {...spaceUpsert(), 'model': 'Missing'}),
    ('a create operation', {...spaceUpsert(), 'operation': 'create'}),
    ('an update operation', {...spaceUpsert(), 'operation': 'update'}),
    ('a wrong schema version', {...spaceUpsert(), 'schemaVersion': 1}),
    (
      'an extra identity component',
      {
        ...spaceUpsert(),
        'id': {'id': spaceId, 'extra': ownerId},
      },
    ),
    (
      'a missing composite identity component',
      {
        'syncId': 101,
        'model': 'Star',
        'operation': 'delete',
        'id': {'userId': ownerId},
      },
    ),
    (
      'an invalid identity scalar',
      {
        ...spaceUpsert(),
        'id': {'id': 'nope'},
      },
    ),
    (
      'a missing required value',
      {
        ...spaceUpsert(),
        'data': {...spaceData()}..remove('name'),
      },
    ),
    (
      'an identity value in data',
      {
        ...spaceUpsert(),
        'data': {...spaceData(), 'id': spaceId},
      },
    ),
    (
      'a wrong scalar',
      {
        ...spaceUpsert(),
        'data': {...spaceData(), 'name': false},
      },
    ),
    (
      'an unsafe int',
      {
        ...spaceUpsert(),
        'data': {...spaceData(), 'memberCount': 9007199254740992},
      },
    ),
    (
      'a non-UTC dateTime',
      {
        ...spaceUpsert(),
        'data': {...spaceData(), 'archivedAt': '2026-08-03T12:00:00-07:00'},
      },
    ),
    (
      'an unknown enum',
      {
        ...spaceUpsert(),
        'data': {...spaceData(), 'kind': 'unknown'},
      },
    ),
    (
      'an invalid list element',
      {
        ...spaceUpsert(),
        'data': {
          ...spaceData(),
          'spaceOrder': [spaceId, 7],
        },
      },
    ),
    ('delete data', {...spaceDelete(), 'data': <String, Object?>{}}),
  ]) {
    test('rejects $label', () {
      expect(
        () => decoder.decode(address(raw)),
        throwsA(isA<DownlinkDataException>()),
      );
    });
  }
}
