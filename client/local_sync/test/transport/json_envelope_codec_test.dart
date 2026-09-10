import 'dart:convert';
import 'dart:typed_data';

import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

import '../support/never_registry_entry.dart';
import '../support/wire_models.dart';

void main() {
  final registry = ModelRegistry([
    NeverModelRegistryEntry(spaceSchema),
    NeverModelRegistryEntry(starSchema),
  ]);
  const clientId = 'f2b1c7d4-8e3a-4b16-9c25-0d7e6a1b3c48';
  const userScope = 'User:$ownerId';
  final codec = LocalSyncJsonCodec(registry: registry);
  final multiScopeCodec = LocalSyncJsonCodec(registry: registry);
  const wireScope = userScope;

  Map<String, Object?> readBytes(Uint8List bytes) =>
      (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();

  Uint8List writeBytes(Object? value) =>
      Uint8List.fromList(utf8.encode(jsonEncode(value)));

  StoredMutationOperation row({
    required int ordinal,
    required String operation,
    required String identityJson,
    required String valuesJson,
    String model = 'Space',
    int? mutationOrdinal,
    bool wire = true,
  }) {
    final parentOrdinal = mutationOrdinal ?? ordinal;
    return StoredMutationOperation(
      mutationOrdinal: parentOrdinal,
      position: ordinal - parentOrdinal,
      model: model,
      identityJson: identityJson,
      operation: operation,
      valuesJson: valuesJson,
      // Every operation names the act it spells (CAP-444); these are one-operation
      // acts, so the record's ordinal is the operation's own.
      isUplink: wire,
    );
  }

  /// The named records the given operations belong to.
  Map<int, StoredMutation> records(
    List<StoredMutationOperation> rows, {
    String name = 'CapturePage',
  }) => {
    for (final row in rows)
      row.mutationOrdinal: StoredMutation(
        ordinal: row.mutationOrdinal,
        name: name,
        legacyFifo: false,
      ),
  };

  /// The operations of the batch's single act.
  List<Map<String, Object?>> operationsOf(Uint8List bytes) {
    final element =
        ((readBytes(bytes)['mutations']! as List<Object?>).single! as Map)
            .cast<String, Object?>();
    return (element['operations']! as List<Object?>)
        .map((operation) => (operation! as Map).cast<String, Object?>())
        .toList();
  }

  final spaceIdentityJson = jsonEncode({'id': spaceId});
  final spaceValuesJson = jsonEncode(spaceData());

  group('encodeUplinkRequest', () {
    test('emits the approved envelope for a create', () {
      final rows = [
        row(
          ordinal: 41,
          operation: 'create',
          identityJson: spaceIdentityJson,
          valuesJson: spaceValuesJson,
        ),
      ];
      final bytes = codec.encodeUplinkRequest(
        clientId: clientId,
        batchSequence: 7,
        mutations: rows,
        records: records(rows),
      );

      final envelope = readBytes(bytes);
      expect(envelope['clientId'], clientId);
      expect(envelope['batchSequence'], 7);
      final mutations = envelope['mutations']! as List<Object?>;
      expect(mutations, hasLength(1));
      // One named act, positioned by the ordinal of its first operation, with
      // the operations riding inside it.
      final act = (mutations.single! as Map).cast<String, Object?>();
      expect(act['ordinal'], 41);
      expect(act['name'], 'CapturePage');

      final operation = (act['operations']! as List<Object?>).single! as Map;
      expect(operation['model'], 'Space');
      expect(operation['op'], 'create');
      expect(operation['identity'], {'id': spaceId});
      // The value codec's canonical forms, not the caller's spelling: the
      // envelope carries what the codec normalized, dateTimes included.
      expect(operation['values'], {
        ...spaceData(),
        'eventTimes': ['2026-08-03T19:00:00.000Z'],
      });
    });

    test('keeps key order stable across encodings', () {
      final rows = [
        row(
          ordinal: 41,
          operation: 'create',
          identityJson: spaceIdentityJson,
          valuesJson: spaceValuesJson,
        ),
      ];
      Uint8List encode() => codec.encodeUplinkRequest(
        clientId: clientId,
        batchSequence: 7,
        mutations: rows,
        records: records(rows),
      );

      expect(utf8.decode(encode()), utf8.decode(encode()));
      expect(
        utf8.decode(encode()),
        startsWith('{"clientId":"$clientId","batchSequence":7,"mutations":['),
      );
      expect(
        utf8.decode(encode()),
        contains(
          '{"ordinal":41,"name":"CapturePage","operations":'
          '[{"model":"Space","op":"create",',
        ),
      );
    });

    test('carries a null value as an explicit clear on an update', () {
      final rows = [
        row(
          ordinal: 1,
          operation: 'update',
          identityJson: spaceIdentityJson,
          valuesJson: jsonEncode({'archivedAt': null}),
        ),
      ];
      final bytes = codec.encodeUplinkRequest(
        clientId: clientId,
        batchSequence: 8,
        mutations: rows,
        records: records(rows),
      );

      final operation = operationsOf(bytes).single;
      expect(operation['op'], 'update');
      expect(operation['values'], {'archivedAt': null});
    });

    test('omits values entirely for a delete', () {
      final rows = [
        row(
          ordinal: 2,
          operation: 'delete',
          identityJson: spaceIdentityJson,
          valuesJson: '{}',
        ),
      ];
      final bytes = codec.encodeUplinkRequest(
        clientId: clientId,
        batchSequence: 9,
        mutations: rows,
        records: records(rows),
      );

      final operation = operationsOf(bytes).single;
      expect(operation['op'], 'delete');
      expect(operation.containsKey('values'), isFalse);
    });

    test('carries every operation of one act in slot order', () {
      final rows = [
        row(
          ordinal: 5,
          operation: 'create',
          identityJson: spaceIdentityJson,
          valuesJson: spaceValuesJson,
          mutationOrdinal: 5,
          wire: true,
        ),
        row(
          ordinal: 6,
          model: 'Star',
          operation: 'delete',
          identityJson: jsonEncode({'userId': ownerId, 'momentId': momentId}),
          valuesJson: '{}',
          mutationOrdinal: 5,
          wire: true,
        ),
      ];
      final bytes = codec.encodeUplinkRequest(
        clientId: clientId,
        batchSequence: 2,
        mutations: rows,
        records: records(rows),
      );

      // One element, two operations: the act is the wire's unit, and an
      // operation inside it is addressed but never positioned.
      expect((readBytes(bytes)['mutations']! as List<Object?>), hasLength(1));
      final operations = operationsOf(bytes);
      expect(operations.map((operation) => operation['model']), [
        'Space',
        'Star',
      ]);
      expect(
        operations.every((operation) => !operation.containsKey('ordinal')),
        isTrue,
      );
    });

    test('validates scalars through the value codec', () {
      final rows = [
        row(
          ordinal: 1,
          operation: 'create',
          identityJson: spaceIdentityJson,
          valuesJson: jsonEncode({...spaceData(), 'kind': 'nonsense'}),
        ),
      ];
      expect(
        () => codec.encodeUplinkRequest(
          clientId: clientId,
          batchSequence: 1,
          mutations: rows,
          records: records(rows),
        ),
        throwsA(isA<UplinkDataException>()),
      );
    });

    test('rejects an unsynced Model', () {
      final rows = [
        row(
          ordinal: 1,
          model: 'Missing',
          operation: 'create',
          identityJson: spaceIdentityJson,
          valuesJson: spaceValuesJson,
        ),
      ];
      expect(
        () => codec.encodeUplinkRequest(
          clientId: clientId,
          batchSequence: 1,
          mutations: rows,
          records: records(rows),
        ),
        throwsA(isA<UplinkDataException>()),
      );
    });
  });

  group('decodeUplinkResponse', () {
    test('decodes an accepted batch', () {
      final response = codec.decodeUplinkResponse(
        writeBytes({
          'requiredScope': wireScope,
          'requiredSyncId': 118,
          'rejections': <Object?>[],
        }),
        requestMutationIds: {41},
      );

      expect(response.legacyPrincipalCheckpoint.scope, userScope);
      expect(response.legacyPrincipalCheckpoint.syncId, 118);
      expect(response.requiredCheckpoints, hasLength(1));
      expect(response.requiredCheckpoints.single.scope, userScope);
      expect(response.requiredCheckpoints.single.syncId, 118);
      expect(response.rejections, isEmpty);
    });

    test(
      'prefers a multi-scope checkpoint list while retaining the legacy principal',
      () {
        const bookScope = 'Book:$spaceId';

        final response = multiScopeCodec.decodeUplinkResponse(
          writeBytes({
            'requiredCheckpoints': [
              {'scope': bookScope, 'syncId': 41},
              {'scope': wireScope, 'syncId': 118},
            ],
            'requiredScope': wireScope,
            'requiredSyncId': 118,
            'rejections': <Object?>[],
          }),
          requestMutationIds: {41},
        );

        expect(
          response.requiredCheckpoints.map((checkpoint) => checkpoint.scope),
          [bookScope, userScope],
        );
        expect(
          response.requiredCheckpoints.map((checkpoint) => checkpoint.syncId),
          [41, 118],
        );
        expect(response.legacyPrincipalCheckpoint.scope, userScope);
        expect(response.legacyPrincipalCheckpoint.syncId, 118);
      },
    );

    for (final (label, checkpoints) in <(String, Object?)>[
      ('an empty checkpoint list', <Object?>[]),
      (
        'a duplicate checkpoint scope',
        [
          {'scope': wireScope, 'syncId': 1},
          {'scope': wireScope, 'syncId': 2},
        ],
      ),
    ]) {
      test('rejects $label', () {
        expect(
          () => codec.decodeUplinkResponse(
            writeBytes({
              'requiredCheckpoints': checkpoints,
              'requiredScope': wireScope,
              'requiredSyncId': 1,
              'rejections': <Object?>[],
            }),
            requestMutationIds: const {1},
          ),
          throwsA(isA<UplinkDataException>()),
        );
      });
    }

    test('accepts arbitrary required scope text which is not demanded', () {
      const inactive = 'anything at all';

      final response = codec.decodeUplinkResponse(
        writeBytes({
          'requiredScope': inactive,
          'requiredSyncId': 7,
          'rejections': <Object?>[],
        }),
        requestMutationIds: const {1},
      );

      expect(response.legacyPrincipalCheckpoint.scope, inactive);
      expect(response.legacyPrincipalCheckpoint.syncId, 7);
      expect(response.requiredCheckpoints.single.scope, inactive);
      expect(response.requiredCheckpoints.single.syncId, 7);
    });

    test('rejects the retired structured required scope', () {
      expect(
        () => codec.decodeUplinkResponse(
          writeBytes({
            'requiredScope': {'model': 'User', 'id': ownerId},
            'requiredSyncId': 7,
            'rejections': <Object?>[],
          }),
          requestMutationIds: const {1},
        ),
        throwsA(isA<UplinkDataException>()),
      );
    });

    test('decodes positional rejections with their codes', () {
      final response = codec.decodeUplinkResponse(
        writeBytes({
          'requiredScope': wireScope,
          'requiredSyncId': 9,
          'rejections': [
            {'ordinal': 41, 'code': 'mutation.invalid'},
          ],
        }),
        requestMutationIds: {41, 42},
      );

      expect(response.rejections, hasLength(1));
      expect(response.rejections.single.mutationId, 41);
      expect(response.rejections.single.code, 'mutation.invalid');
    });

    test('ignores unknown fields on read', () {
      final response = codec.decodeUplinkResponse(
        writeBytes({
          'requiredScope': wireScope,
          'requiredSyncId': 3,
          'rejections': [
            {'ordinal': 41, 'code': 'space.locked', 'detail': 'ignored'},
          ],
          'serverNote': 'ignored',
        }),
        requestMutationIds: {41},
      );

      expect(response.legacyPrincipalCheckpoint.syncId, 3);
      expect(response.rejections.single.code, 'space.locked');
    });

    for (final (label, body) in <(String, Object?)>[
      (
        'a negative requiredSyncId',
        {'requiredSyncId': -1, 'rejections': <Object?>[]},
      ),
      (
        'an unrequested rejection',
        {
          'requiredSyncId': 1,
          'rejections': [
            {'ordinal': 99, 'code': 'x'},
          ],
        },
      ),
      (
        'a duplicate rejection',
        {
          'requiredSyncId': 1,
          'rejections': [
            {'ordinal': 41, 'code': 'x'},
            {'ordinal': 41, 'code': 'y'},
          ],
        },
      ),
      (
        'an empty rejection code',
        {
          'requiredSyncId': 1,
          'rejections': [
            {'ordinal': 41, 'code': ''},
          ],
        },
      ),
      ('a missing requiredSyncId', {'rejections': <Object?>[]}),
    ]) {
      test('rejects $label', () {
        expect(
          () => codec.decodeUplinkResponse(
            writeBytes({
              'requiredScope': wireScope,
              ...(body as Map<String, Object?>),
            }),
            requestMutationIds: {41},
          ),
          throwsA(isA<UplinkDataException>()),
        );
      });
    }

    test('rejects a missing required Scope', () {
      expect(
        () => codec.decodeUplinkResponse(
          writeBytes({'requiredSyncId': 1, 'rejections': <Object?>[]}),
          requestMutationIds: {41},
        ),
        throwsA(isA<UplinkDataException>()),
      );
    });

    test('rejects bytes that are not JSON', () {
      expect(
        () => codec.decodeUplinkResponse(
          Uint8List.fromList([0x00, 0x01, 0x02]),
          requestMutationIds: {41},
        ),
        throwsA(isA<UplinkDataException>()),
      );
    });
  });

  group('encodeDownlinkRequest', () {
    test('names the cursor and the page it will accept', () {
      final envelope = readBytes(
        codec.encodeDownlinkRequest(
          clientId: clientId,
          scope: userScope,
          afterSyncId: 118,
        ),
      );

      expect(envelope, {
        'clientId': clientId,
        'scope': userScope,
        'fromCursor': 118,
      });
    });

    test('rejects a non-UUID client', () {
      expect(
        () => codec.encodeDownlinkRequest(
          clientId: 'nope',
          scope: userScope,
          afterSyncId: 0,
        ),
        throwsA(isA<UplinkDataException>()),
      );
    });

    test('rejects a negative cursor', () {
      expect(
        () => codec.encodeDownlinkRequest(
          clientId: clientId,
          scope: userScope,
          afterSyncId: -1,
        ),
        throwsA(isA<DownlinkDataException>()),
      );
    });
  });

  group('live handshake', () {
    const bookScope = 'Book:$spaceId';

    test('encodes one canonical subscribe set', () {
      final envelope = readBytes(
        codec.encodeDownlinkSubscribe([userScope, bookScope, userScope]),
      );

      expect(envelope, {
        'type': 'subscribe',
        'scopes': [bookScope, wireScope],
      });
    });

    test('decodes a subscribed acknowledgement independent of order', () {
      final message = codec.decodeDownlinkLiveMessage(
        writeBytes({
          'type': 'subscribed',
          'scopes': [wireScope, bookScope],
          'rejections': <Object?>[],
        }),
      );

      expect(message, isA<DownlinkSubscribed>());
      expect((message as DownlinkSubscribed).scopes, [bookScope, userScope]);
      expect(message.rejections, isEmpty);
    });

    test('decodes accepted and rejected scopes as one partition', () {
      final message =
          codec.decodeDownlinkLiveMessage(
                writeBytes({
                  'type': 'subscribed',
                  'scopes': [wireScope],
                  'rejections': [
                    {'scope': bookScope, 'code': 'scope.forbidden'},
                  ],
                }),
              )
              as DownlinkSubscribed;

      expect(message.scopes, [userScope]);
      expect(message.rejections, hasLength(1));
      expect(message.rejections.single.scope, bookScope);
      expect(message.rejections.single.code, 'scope.forbidden');
    });

    test('decodes an all-rejected acknowledgement', () {
      final message =
          codec.decodeDownlinkLiveMessage(
                writeBytes({
                  'type': 'subscribed',
                  'scopes': <Object?>[],
                  'rejections': [
                    {'scope': wireScope, 'code': 'scope.forbidden'},
                  ],
                }),
              )
              as DownlinkSubscribed;

      expect(message.scopes, isEmpty);
      expect(message.rejections.single.scope, userScope);
    });

    test('decodes the ordinary scoped page as a live page', () {
      final message = codec.decodeDownlinkLiveMessage(
        writeBytes({
          'scope': wireScope,
          'fromCursor': 4,
          'toCursor': 4,
          'changes': <Object?>[],
        }),
      );

      expect(message, isA<DownlinkLivePage>());
      expect((message as DownlinkLivePage).page.scope, userScope);
    });

    test('rejects an empty outbound subscribe set', () {
      expect(
        () => codec.encodeDownlinkSubscribe(const []),
        throwsA(isA<DownlinkDataException>()),
      );
    });

    test('rejects malformed acknowledgement partitions', () {
      for (final envelope in <Map<String, Object?>>[
        {
          'type': 'subscribed',
          'scopes': [wireScope],
        },
        {
          'type': 'subscribed',
          'scopes': [wireScope, wireScope],
          'rejections': <Object?>[],
        },
        {
          'type': 'subscribed',
          'scopes': <Object?>[],
          'rejections': [
            {'scope': wireScope, 'code': 'scope.forbidden'},
            {'scope': wireScope, 'code': 'scope.forbidden'},
          ],
        },
        {
          'type': 'subscribed',
          'scopes': <Object?>[],
          'rejections': [
            {'scope': wireScope, 'code': ''},
          ],
        },
      ]) {
        expect(
          () => codec.decodeDownlinkLiveMessage(writeBytes(envelope)),
          throwsA(isA<DownlinkDataException>()),
        );
      }
    });

    test('requires rejections even when accepted scopes are empty', () {
      expect(
        () => codec.decodeDownlinkLiveMessage(
          writeBytes({'type': 'subscribed', 'scopes': <Object?>[]}),
        ),
        throwsA(isA<DownlinkDataException>()),
      );
    });

    test('rejects the retired structured acknowledged scope', () {
      expect(
        () => codec.decodeDownlinkLiveMessage(
          writeBytes({
            'type': 'subscribed',
            'scopes': [
              {'model': 'User', 'id': ownerId},
            ],
            'rejections': <Object?>[],
          }),
        ),
        throwsA(isA<DownlinkDataException>()),
      );
    });
  });

  group('decodeDownlinkPage', () {
    Uint8List page(List<Object?> changes, {int from = 118, int to = 123}) =>
        writeBytes({
          'scope': wireScope,
          'fromCursor': from,
          'toCursor': to,
          'changes': changes,
        });

    test('reads a present state as an upsert', () {
      final decoded = codec.decodeDownlinkPage(
        page([
          {
            'syncId': 119,
            'model': 'Space',
            'identity': {'id': spaceId},
            'state': spaceData(),
          },
        ]),
      );

      expect(decoded.fromSyncId, 118);
      expect(decoded.scope, userScope);
      expect(decoded.throughSyncId, 123);
      final change = decoded.changes.single;
      expect(change.syncId, 119);
      expect(change.raw, {
        'syncId': 119,
        'model': 'Space',
        'operation': 'upsert',
        'id': {'id': spaceId},
        'data': spaceData(),
      });
    });

    test('reads an absent state as a delete', () {
      final decoded = codec.decodeDownlinkPage(
        page([
          {
            'syncId': 119,
            'model': 'Space',
            'identity': {'id': spaceId},
            'state': null,
          },
        ]),
      );

      expect(decoded.changes.single.raw, {
        'syncId': 119,
        'model': 'Space',
        'operation': 'delete',
        'id': {'id': spaceId},
      });
    });

    test('feeds the change decoder without further translation', () {
      final decoded = codec.decodeDownlinkPage(
        page([
          {
            'syncId': 119,
            'model': 'Space',
            'identity': {'id': spaceId},
            'state': spaceData(),
          },
        ]),
      );

      final change = ModelChangeDecoder(
        registry,
      ).decode(decoded.changes.single);
      expect(change.operation, DownlinkOperation.upsert);
      expect(change.id, SpaceId(uuid(spaceId)));
      expect(change.values['name'], 'Family');
    });

    test('carries a composite identity through', () {
      final decoded = codec.decodeDownlinkPage(
        page([
          {
            'syncId': 119,
            'model': 'Star',
            'identity': {'userId': ownerId, 'momentId': momentId},
            'state': null,
          },
        ]),
      );

      expect(decoded.changes.single.raw['id'], {
        'userId': ownerId,
        'momentId': momentId,
      });
    });

    test('ignores unknown fields on read', () {
      final decoded = codec.decodeDownlinkPage(
        writeBytes({
          'scope': wireScope,
          'fromCursor': 118,
          'toCursor': 123,
          'changes': [
            {
              'syncId': 119,
              'model': 'Space',
              'identity': {'id': spaceId},
              'state': null,
              'issuedAt': 'ignored',
            },
          ],
          'serverNote': 'ignored',
        }),
      );

      expect(decoded.changes, hasLength(1));
    });

    test('rejects the retired structured page scope', () {
      expect(
        () => codec.decodeDownlinkPage(
          writeBytes({
            'scope': {'model': 'User', 'id': ownerId},
            'fromCursor': 118,
            'toCursor': 118,
            'changes': <Object?>[],
          }),
        ),
        throwsA(isA<DownlinkDataException>()),
      );
    });

    test('accepts an empty page', () {
      final decoded = codec.decodeDownlinkPage(page(const [], to: 118));

      expect(decoded.changes, isEmpty);
      expect(decoded.throughSyncId, 118);
    });

    for (final (label, body) in <(String, Object?)>[
      (
        'a page that walks backwards',
        {'fromCursor': 120, 'toCursor': 119, 'changes': <Object?>[]},
      ),
      (
        'a negative cursor',
        {'fromCursor': -1, 'toCursor': 5, 'changes': <Object?>[]},
      ),
      (
        'a change with no model',
        {
          'fromCursor': 1,
          'toCursor': 5,
          'changes': [
            {
              'syncId': 2,
              'identity': {'id': spaceId},
              'state': null,
            },
          ],
        },
      ),
      (
        'a change with no identity',
        {
          'fromCursor': 1,
          'toCursor': 5,
          'changes': [
            {'syncId': 2, 'model': 'Space', 'schemaVersion': 2, 'state': null},
          ],
        },
      ),
      (
        'a change with no syncId',
        {
          'fromCursor': 1,
          'toCursor': 5,
          'changes': [
            {
              'model': 'Space',
              'identity': {'id': spaceId},
              'state': null,
            },
          ],
        },
      ),
      (
        'changes that do not ascend',
        {
          'fromCursor': 1,
          'toCursor': 9,
          'changes': [
            {
              'syncId': 3,
              'model': 'Space',
              'identity': {'id': spaceId},
              'state': null,
            },
            {
              'syncId': 3,
              'model': 'Space',
              'identity': {'id': spaceId},
              'state': null,
            },
          ],
        },
      ),
      (
        'a change past the page end',
        {
          'fromCursor': 1,
          'toCursor': 5,
          'changes': [
            {
              'syncId': 6,
              'model': 'Space',
              'identity': {'id': spaceId},
              'state': null,
            },
          ],
        },
      ),
    ]) {
      test('rejects $label', () {
        expect(
          () => codec.decodeDownlinkPage(
            writeBytes({'scope': wireScope, ...(body as Map<String, Object?>)}),
          ),
          throwsA(isA<DownlinkDataException>()),
        );
      });
    }

    test('rejects bytes that are not JSON', () {
      expect(
        () => codec.decodeDownlinkPage(Uint8List.fromList([0x00, 0x01])),
        throwsA(isA<DownlinkDataException>()),
      );
    });
  });
}
