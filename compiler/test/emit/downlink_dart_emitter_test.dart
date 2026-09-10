import 'package:local_sync_compiler/local_sync_compiler.dart';
import 'package:test/test.dart';

void main() {
  final graph = compileModelSources({
    'space.model': '''model Space {
  id UUID
  name String
  archivedAt DateTime?
  @@id(id)
}''',
    'draft.model': '''model Draft {
  id UUID
  text String
  @@id(id)
}''',
  });

  test('emits declarative model storage and runtime composition', () {
    final output = emitDart(graph);

    expect(output, containsPair('model_registry.dart', anything));
    expect(output, isNot(contains('model_schema_registry.dart')));
    expect(
      output['storage/space.dart'],
      allOf(
        contains('ModelDatabaseDescriptor<SpaceId>'),
        contains('CREATE TABLE "model_space"'),
        contains('"archived_at" TEXT'),
      ),
    );
    expect(output['local_sync.dart'], contains('ModelChangeDecoder(registry)'));
    expect(output['local_sync.dart'], isNot(contains('ModelActionDecoder')));
  });

  test('composes one typed registry without generated algorithms', () {
    final output = emitDart(graph);
    final registry = output['model_registry.dart']!;

    expect(registry, contains('ModelRegistry buildModelRegistry'));
    expect(registry, contains('TypedModelRegistryEntry<SpaceId>'));
    // Every Model is registered and none carries a mode: a Model describes a
    // row shape and says nothing about replication (CAP-488).
    expect(registry, contains('TypedModelRegistryEntry<DraftId>'));
    expect(registry, isNot(contains('synced')));
    expect(registry, contains('SqlCanonicalStore<SpaceId>'));
    expect(registry, contains('descriptor: spaceDatabaseDescriptor'));

    final generated = output.values.join('\n');
    for (final forbidden in [
      'jsonDecode(',
      'switch (action.operation)',
      'while (lastAppliedSyncId',
      'statusCode ==',
      'DownlinkChangeException',
    ]) {
      expect(generated, isNot(contains(forbidden)), reason: forbidden);
    }
  });

  test('emits one closed typed canonical Downlink change union', () {
    final output = emitDart(graph);
    final changes = output['downlink_changes.dart']!;

    expect(changes, contains('sealed class LocalSyncDownlinkChange'));
    expect(changes, contains('final class SpaceDownlinkUpsert'));
    expect(changes, contains('final Space? previous;'));
    expect(changes, contains('final Space row;'));
    expect(changes, contains('final class SpaceDownlinkDelete'));
    expect(changes, contains('final String scope;'));
    expect(changes, contains('final int syncId;'));
    expect(
      changes,
      allOf(
        contains('LocalSyncDownlinkChanges materializeDownlinkChanges('),
        contains('List<CanonicalDownlinkChange> changes,'),
      ),
    );
    expect(
      output['local_sync.dart'],
      contains("export 'downlink_changes.dart';"),
    );
    expect(output['local_sync.dart'], contains('onDownlinkApplied'));
    expect(
      output['local_sync.dart'],
      allOf(
        contains('onApplied: onDownlinkApplied == null'),
        contains(': (changes) => transactionContexts.run('),
      ),
    );
  });
}
