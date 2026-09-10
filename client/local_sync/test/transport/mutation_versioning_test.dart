import 'dart:convert';

import 'package:local_sync/local_sync.dart';
import 'package:local_sync/src/uplink/queued_mutation.dart';
import 'package:test/test.dart';

import '../support/never_registry_entry.dart';
import '../support/wire_models.dart';

void main() {
  const client = 'f2b1c7d4-8e3a-4b16-9c25-0d7e6a1b3c48';
  final oldShape = <String, Object?>{
    'enumValues': <String, Object?>{},
    'models': {
      'space': {
        'name': 'Space',
        'identityFields': ['id'],
        'fields': [
          {
            'name': 'id',
            'identity': true,
            'nullable': false,
            'type': {'kind': 'scalar', 'name': 'uuid'},
          },
          {
            'name': 'name',
            'identity': false,
            'nullable': false,
            'type': {'kind': 'scalar', 'name': 'string'},
          },
          {
            'name': 'ownerId',
            'identity': false,
            'nullable': true,
            'type': {'kind': 'scalar', 'name': 'uuid'},
            'prerequisite': {
              'name': 'OriginalUpload',
              'arguments': {'key': 'ownerId'},
            },
          },
        ],
      },
    },
  };
  final registry = ModelRegistry(
    [NeverModelRegistryEntry(spaceSchema)],
    mutationInputs: MutationInputContracts({
      'CreateSpace': {1: oldShape},
    }),
  );
  final codec = LocalSyncJsonCodec(registry: registry);
  final operation = StoredMutationOperation(
    mutationOrdinal: 1,
    mutationName: 'CreateSpace',
    mutationVersion: 1,
    position: 0,
    model: 'Space',
    operation: 'create',
    isUplink: true,
    identityJson: jsonEncode({'id': spaceId}),
    valuesJson: jsonEncode({'name': 'An old queued page', 'ownerId': ownerId}),
  );
  Map<String, Object?> encode(int? version) =>
      (jsonDecode(
                utf8.decode(
                  codec.encodeUplinkRequest(
                    clientId: client,
                    batchSequence: 1,
                    mutations: [operation],
                    records: {
                      1: StoredMutation(
                        ordinal: 1,
                        name: 'CreateSpace',
                        version: version,
                        legacyFifo: false,
                      ),
                    },
                  ),
                ),
              )
              as Map)
          .cast<String, Object?>();

  test('historical create does not acquire current required fields', () {
    final body = encode(1);
    final act = (body['mutations'] as List).single as Map;
    expect(act['version'], 1);
    final values = ((act['operations'] as List).single as Map)['values'];
    expect(values, {'name': 'An old queued page', 'ownerId': ownerId});
  });

  test('legacy omitted version stays absent while selecting historical v1', () {
    final act = (encode(null)['mutations'] as List).single as Map;
    expect(act.containsKey('version'), isFalse);
  });

  test('historical readiness uses the original prerequisite declaration', () {
    final prerequisites = prerequisiteInvocationsOf(registry, [
      operation,
    ]).toList();
    expect(prerequisites, hasLength(1));
    expect(prerequisites.single.name, 'OriginalUpload');
    expect(prerequisites.single.arguments['key'], UUID.fromString(ownerId));
  });

  test('missing historical version fails rather than encoding as latest', () {
    expect(() => encode(2), throwsA(isA<StateError>()));
  });
}
