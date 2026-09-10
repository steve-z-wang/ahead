import 'package:local_sync_compiler/local_sync_compiler.dart';
import 'package:test/test.dart';

void main() {
  final contract = buildBackendContract(
    compileModelSources({
      'models.model': '''
enum SpaceKind {
  personal
  group
}

model Space {
  id UUID
  ownerId UUID
  kind SpaceKind
  nickname String?
  count Int
  tags String[]
  @@id(id)
}

model Star {
  userId UUID
  momentId UUID
  createdAt DateTime
  @@id(userId, momentId)
}

model LocalNote {
  id UUID
  body String
  @@id(id)
}
''',
    }),
  );

  test('emits typed binding declarations and the Model registry', () {
    final emission = emitBackendTypescript(contract);
    final output = emission.backendContract;

    expect(output, contains("from 'local-sync-backend';"));
    // The wire is handwritten and fixed, so nothing generated imports one.
    expect(output, isNot(contains('Message,')));
    expect(output, isNot(contains("from '../proto/local_sync';")));
    expect(
      output,
      contains('''export type SpaceIdentity = Readonly<{
  id: string;
}>;'''),
    );
    expect(
      output,
      contains('''export type SpaceState = Readonly<{
  count: number;
  id: string;
  kind: 'personal' | 'group';
  nickname: string | null;
  ownerId: string;
  tags: readonly string[];
}>;'''),
    );
    expect(
      output,
      contains('''export type SpaceCreateData = Readonly<{
  count: number;
  kind: 'personal' | 'group';
  nickname: string | null;
  ownerId: string;
  tags: readonly string[];
}>;'''),
    );
    expect(
      output,
      contains('''export type SpacePatch = Readonly<{
  count?: number;
  kind?: 'personal' | 'group';
  nickname?: string | null;
  ownerId?: string;
  tags?: readonly string[];
}>;'''),
    );
    expect(
      output,
      contains('''export type SpaceBackendBinding<TTx> = BackendModelBinding<
  TTx,
  SpaceIdentity,
  SpaceState
>;'''),
    );
    expect(
      output,
      // Every generated Model, and every key optional: which of them reaches
      // the Downlink is the Backend's own choice, made by registering a
      // loader for it (CAP-488). The types stay exact — an unknown key or a
      // mismatched binding is still a compile error.
      contains('''export type GeneratedBackendModelBindings<TTx> = Readonly<{
  localNote?: LocalNoteBackendBinding<TTx>;
  space?: SpaceBackendBinding<TTx>;
  star?: StarBackendBinding<TTx>;
}>;'''),
    );
    // The Downlink has one source and it is `LocalSyncInvalidation`
    // (CAP-482). There is no second product registry to generate: what the
    // loader answers content for is what publication already claimed.
    for (final gone in [
      'BackendModelEnumeration',
      'LocalSyncEnumerations',
      'BackendEnumeration',
    ]) {
      expect(output, isNot(contains(gone)), reason: gone);
    }
    // A binding is the read half alone: writes are per ACT (CAP-444).
    expect(output, isNot(contains('binding.write')));
    expect(
      output,
      contains('''return binding.read.forViewer(context, identities);'''),
    );
    expect(output, contains("name: 'Space'"));
    expect(
      output,
      contains("enumValues: {\n    SpaceKind: ['personal', 'group'],\n  }"),
    );
    expect(output, contains("identityFields: ['id']"));
    expect(output, isNot(contains('protobuf:')));
    expect(output, isNot(contains('cases:')));
    expect(output, contains('forward: { read: forwardSpaceRead }'));
    expect(output, isNot(contains('forwardSpaceCreate')));
    expect(output, contains('satisfies GeneratedBackendContract'));
    expect(output, contains("name: 'LocalNote'"));

    for (final declaration in const [
      'interface UplinkRequest',
      'type UplinkRequest',
      'interface ModelMutation',
      'type ModelMutation',
      'interface ModelChange',
      'type ModelChange',
      'interface SpaceCreateMutation',
    ]) {
      expect(output, isNot(contains(declaration)));
    }
  });

  test('emits one file, and it stands no server up', () {
    final emission = emitBackendTypescript(contract);

    expect(emission.files.keys, ['backend_contract.ts']);
    final all = emission.backendContract;
    expect(all, endsWith('\n'));
    expect(all, isNot(endsWith('\n\n')));
    for (final absent in const [
      '@nestjs',
      '@grpc/grpc-js',
      'local-sync-grpc',
      'createLocalSyncBackend',
      'LocalSyncHost',
    ]) {
      expect(all, isNot(contains(absent)), reason: absent);
    }

    for (final forbidden in const [
      'beginTransaction',
      'transaction(',
      'savepoint',
      'allocateSync',
      'batchSequence <',
      'batchSequence >',
      'while (',
      'for await',
      'subscribeDownlink(',
      '.invalidate(',
      'backend/src',
      'Prisma',
      'Firebase',
      'DomainService',
    ]) {
      expect(all, isNot(contains(forbidden)), reason: forbidden);
    }
  });
}
