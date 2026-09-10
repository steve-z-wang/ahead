import 'dart:convert';
import 'dart:typed_data';

import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

import '../support/never_registry_entry.dart';
import '../support/wire_models.dart';

/// Legacy queue rows keep their original omitted-version wire spelling after
/// CAP-728. Their effective mutation version is v1; preserving absence keeps
/// already-committed receipt hashes stable across client upgrades.
///
/// The server's half lives beside the server, in
/// `local-sync/server/test/wire-contract.spec.ts`.
void main() {
  final registry = ModelRegistry([NeverModelRegistryEntry(spaceSchema)]);
  const clientId = 'f2b1c7d4-8e3a-4b16-9c25-0d7e6a1b3c48';

  const spaceId = '550e8400-e29b-41d4-a716-446655440000';
  const ownerId = 'b8bec29d-df16-4275-a978-338b228ce80c';
  final codec = LocalSyncJsonCodec(registry: registry);

  Map<String, Object?> readBytes(Uint8List bytes) =>
      (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();

  test('an act names itself, and says nothing about its shape', () {
    final envelope = readBytes(
      codec.encodeUplinkRequest(
        clientId: clientId,
        batchSequence: 1,
        mutations: [
          StoredMutationOperation(
            mutationOrdinal: 1,
            position: 0,
            model: 'Space',
            identityJson: jsonEncode({'id': spaceId}),
            operation: 'create',
            valuesJson: jsonEncode({
              'ownerId': ownerId,
              'name': 'Family',
              'kind': 'group',
              'memberCount': 3,
              'isOpen': true,
              'ratio': 1.5,
              'archivedAt': null,
              'rankOrder': [1, 2],
              'spaceOrder': [spaceId],
              'eventTimes': ['2026-08-03T19:00:00.000Z'],
            }),
            isUplink: true,
          ),
        ],
        records: {
          1: const StoredMutation(
            ordinal: 1,
            name: 'CreateSpace',
            legacyFifo: false,
          ),
        },
      ),
    );

    final act = ((envelope['mutations']! as List<Object?>).single! as Map)
        .cast<String, Object?>();
    expect(act.keys, ['ordinal', 'name', 'operations']);

    final operation = ((act['operations']! as List<Object?>).single! as Map)
        .cast<String, Object?>();
    expect(operation.keys, ['model', 'op', 'identity', 'values']);
  });
}
