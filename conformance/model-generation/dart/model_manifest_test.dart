import 'package:local_sync/local_sync.dart';
import 'package:local_sync_conformance/local_sync_conformance.dart';
import 'package:test/test.dart';

import 'model_manifest.dart';
import 'support.dart';

/// The Dart half of the shared matrix, proved in Dart.
///
/// The manifest is what the other two projections are compared against
/// (`model-generation/typescript/shared-model-contract.spec.ts`), so its three
/// type categories are pinned here, where a normalizer bug reads as a
/// normalizer bug rather than as disagreement between runtimes.
void main() {
  test(
    'projects every declared type category out of the generated registry',
    () async {
      final database = await TestDatabase.create();
      addTearDown(database.dispose);
      final connection = await database.driver.open();
      addTearDown(connection.close);

      final manifest = modelManifest(
        buildModelRegistry(LocalDatabaseScope(connection)),
      );
      final byName = {
        for (final model in manifest) model['name'] as String: model,
      };

      // Every generated Model is in the registry and none carries a mode: a
      // Model describes a row shape and says nothing about replication
      // (CAP-488). Which of them the Backend publishes is its own choice,
      // made by registering a loader.
      expect(byName.keys, contains('LocalNote'));

      expect(byName['Space']!['identity'], ['id']);
      expect(field(byName['Space']!, 'ownerId'), {
        'name': 'ownerId',
        'type': {'kind': 'scalar', 'name': 'uuid'},
        'nullable': false,
      });
      expect(field(byName['Space']!, 'kind'), {
        'name': 'kind',
        'type': {
          'kind': 'enum',
          'name': 'SpaceKind',
          'values': ['personal', 'group'],
        },
        'nullable': false,
      });
      expect(field(byName['AccountState']!, 'spaceOrder'), {
        'name': 'spaceOrder',
        'type': {
          'kind': 'list',
          'element': {'kind': 'scalar', 'name': 'uuid'},
        },
        'nullable': false,
      });
      expect(field(byName['AccountState']!, 'inboxSeenAt'), {
        'name': 'inboxSeenAt',
        'type': {'kind': 'scalar', 'name': 'dateTime'},
        'nullable': true,
      });
      expect(byName['Star']!['identity'], ['userId', 'momentId']);
    },
  );
}

Map<String, Object?> field(Map<String, Object?> model, String name) =>
    (model['fields']! as List).cast<Map<String, Object?>>().singleWhere(
      (candidate) => candidate['name'] == name,
    );
