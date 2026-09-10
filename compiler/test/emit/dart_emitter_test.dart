import 'package:local_sync_compiler/local_sync_compiler.dart';
import 'package:test/test.dart';

void main() {
  final graph = compileModelSources({
    'user.model': '''enum UserKind {
  person
  bot
}

model User {
  id         UUID
  handle     String
  text       String?
  kind       UserKind
  spaceOrder UUID[]
  @@id(id)
  @@unique(handle)
}''',
    'moment.model': '''model Moment {
  id UUID
  @@id(id)
}''',
    'star.model': '''prerequisite RemoteObject(key String)

model Star {
  userId UUID
  momentId UUID
  key String @requires(RemoteObject(key: self))
  user User @reference(via: [userId], onTargetDelete: delete)
  moment Moment @reference(via: [momentId])
  @@id(userId, momentId)
}''',
    'draft.model': '''model Draft {
  id UUID
  text String
  @@id(id)
}''',
  });

  test('emits deterministic types, descriptors, and SQLite DDL', () {
    final output = emitDart(graph);

    expect(
      () => GeneratedOutput.prepare(output),
      returnsNormally,
      reason: 'every emitted Dart file must parse before it is installed',
    );

    expect(output.keys, [
      'composition.dart',
      'downlink_changes.dart',
      'enums.dart',
      'local_sync.dart',
      'local_sync_database.dart',
      'model_registry.dart',
      'models.dart',
      'models/draft.dart',
      'models/moment.dart',
      'models/star.dart',
      'models/user.dart',
      'mutation_input_contracts.dart',
      'mutations.dart',
      'storage/draft.dart',
      'storage/moment.dart',
      'storage/star.dart',
      'storage/user.dart',
    ]);
    expect(output['models/user.dart'], contains('final class UserId'));
    expect(output['enums.dart'], contains('enum UserKind { person, bot }'));
    expect(
      output['enums.dart'],
      contains("const userKindType = LocalEnumType("),
    );
    expect(
      output['models/user.dart'],
      allOf(
        contains('required List<UUID> spaceOrder'),
        contains('final UserKind kind;'),
        contains('final List<UUID> spaceOrder;'),
      ),
    );
    expect(
      output['models/user.dart'],
      allOf(
        contains('type: userKindType'),
        contains('type: LocalScalarListType(LocalScalarType.uuid)'),
      ),
    );
    expect(output['models/user.dart'], contains('final class UserCollection'));
    expect(
      output['models/user.dart'],
      contains('materialize: _materializeUser'),
    );
    expect(
      output['models/user.dart'],
      contains('base class User extends Model<UserId>'),
    );
    expect(output['models/user.dart'], isNot(contains('MutableUser')));
    expect(
      output['models/user.dart'],
      contains('final userSchema = ModelSchema<UserId>'),
    );
    expect(output['models/star.dart'], contains('final class StarId'));
    expect(output['models/star.dart'], contains('required this.userId'));
    expect(
      output['models/star.dart'],
      contains("identity: const ['userId', 'momentId']"),
    );
    expect(output['storage/user.dart'], contains("tableName: 'model_user'"));
    expect(output['storage/user.dart'], contains("'text': 'text'"));
    expect(
      output['storage/user.dart'],
      allOf(
        contains('final userDatabaseDescriptor'),
        contains('final userDatabaseStatements'),
        contains('"kind" TEXT NOT NULL'),
        contains('"space_order" TEXT NOT NULL'),
      ),
    );
    expect(
      output['storage/user.dart'],
      contains('CREATE UNIQUE INDEX "model_user_handle_unique"'),
    );
    // Prerequisites reach only generated client metadata and typed handlers;
    // nothing about them rides the wire.
    expect(output['models/star.dart'], contains('  deleteOnTarget: true,'));
    expect(output['models/star.dart'], contains('  deleteOnTarget: false,'));
    expect(output['models/star.dart'], contains("name: 'RemoteObject',"));
    expect(
      output['models/moment.dart'],
      isNot(contains("name: 'RemoteObject',")),
    );
    // A main table is columns and its primary key, and nothing else: no
    // relation of any kind emits a constraint (CAP-407 spec §2).
    expect(
      output['storage/star.dart'],
      contains('''
      CREATE TABLE "model_star" (
        "user_id" TEXT NOT NULL,
        "moment_id" TEXT NOT NULL,
        "key" TEXT NOT NULL,
        PRIMARY KEY ("user_id", "moment_id")
      )
'''),
    );
    // Before-image twins: identical columns and PK, no constraints and no
    // indexes (they are cold), synced Models only.
    expect(
      output['storage/star.dart'],
      allOf(
        contains('final starBeforeDatabaseDescriptor'),
        contains("tableName: 'model_star_before'"),
        contains('CREATE TABLE "model_star_before"'),
      ),
    );
    expect(
      output['storage/user.dart'],
      isNot(contains('CREATE UNIQUE INDEX "model_user_before')),
    );
    // A local Model carries the twin too since mixed acts: a local slot
    // inside a synced act rolls back with it, and rollback needs the value
    // the act found.
    expect(
      output['storage/draft.dart'],
      allOf(
        contains('final draftBeforeDatabaseDescriptor'),
        contains('CREATE TABLE "model_draft_before"'),
      ),
    );
    expect(
      output['local_sync_database.dart'],
      allOf(
        contains(
          'final localSyncCurrentSchemaStatements = <DatabaseStatement>[',
        ),
        contains('...localSyncInfrastructureStatements,'),
        contains('...userDatabaseStatements,'),
        contains('...starDatabaseStatements,'),
        isNot(contains('SqliteDatabaseMigration(')),
        isNot(contains('local_sync_database_sqlite')),
        isNot(contains('localSyncDatabaseDriver')),
      ),
    );
    expect(
      output['local_sync.dart'],
      allOf(
        contains('final class LocalSyncPrerequisiteHandlers'),
        contains(
          'final Future<PrerequisiteAttemptResult> Function({\n'
          '    required String key,\n'
          '  }) remoteObject;',
        ),
        contains(
          "'RemoteObject': (arguments) => handlers.remoteObject(\n"
          "    key: arguments['key']! as String,",
        ),
        contains('required LocalSyncPrerequisiteHandlers prerequisites,'),
        allOf(
          contains('final prerequisiteRunner = PrerequisiteRunner('),
          contains('handlers: buildPrerequisiteHandlers(prerequisites),'),
          contains('prerequisiteRunner: prerequisiteRunner,'),
        ),
        contains(
          "export 'local_sync_database.dart' "
          'show localSyncCurrentSchemaStatements;',
        ),
        isNot(contains('localSyncDatabaseDriver')),
      ),
    );
    expect(
      output['model_registry.dart'],
      contains('ModelRegistry buildModelRegistry'),
    );
    expect(output['models.dart'], contains('final class Models'));
    // Two surfaces over one set of Models: the reactive one screens read, and
    // the transaction one a write callback holds (CAP-488).
    expect(output['models.dart'], contains('final class TransactionModels'));
    expect(
      output['models/user.dart'],
      allOf(
        contains('final class UserTransactionCollection'),
        contains('  Future<void> create({'),
        contains('  Future<void> update({'),
        contains('  Future<void> delete(UserId id) => writer.delete(id);'),
        // A stream cannot outlive the transaction that gives its reads
        // meaning, so the transaction surface has no `watch` at all.
        isNot(contains('Stream<User?> watch')),
      ),
    );
    expect(
      output['composition.dart'],
      isNot(contains('buildCascadeVisibility')),
    );
    expect(
      output['composition.dart'],
      isNot(contains('MutationPrefixValidator(')),
    );
    expect(
      output['composition.dart'],
      isNot(contains('TransactionValidator(')),
    );
    expect(
      output['composition.dart'],
      contains('beforeDescriptor: userBeforeDatabaseDescriptor'),
    );
    expect(output['composition.dart'], contains('LocalDatabaseScope database'));
    // One substrate per Model, whatever a write later chooses to do with it.
    expect(output['composition.dart'], contains('ModelRuntime<DraftId>'));
    expect(
      output['composition.dart'],
      allOf(
        isNot(contains('LocalModelRuntime')),
        isNot(contains('SyncedModelRuntime')),
        contains('TransactionModels buildTransactionModels('),
        contains('TransactionFateContext context'),
        contains('TransactionModelWriter<DraftId>('),
      ),
    );
    expect(output['composition.dart'], contains('ModelRuntime<UserId>'));
    expect(
      output['composition.dart'],
      isNot(contains('runtimes.draft.validation')),
    );
    // The reactive collection reads; it has no writer at all. A write reaches
    // the row through the transaction collection instead (CAP-488).
    expect(
      output['models/draft.dart'],
      contains(
        'final class DraftCollection extends \n'
        '    ReactiveModelCollection<Draft, DraftId, DraftFields> {\n'
        '  DraftCollection({required ModelReader<DraftId> reader})',
      ),
    );
    expect(
      output['models/draft.dart'],
      contains('required ModelReader<DraftId> reader'),
    );
    expect(
      output['models/draft.dart'],
      isNot(contains('ProjectionReader<DraftId>')),
    );
    expect(
      output['composition.dart'],
      contains('descriptor: userDatabaseDescriptor'),
    );

    // The registry is the only place the graph between Models exists, and a
    // delete has to reach the rows that fall with it, so the write path is
    // handed the registry the runtime already builds — explicitly, as a
    // constructor dependency (CAP-396).
    expect(
      output['composition.dart'],
      contains('required ModelRegistry registry'),
    );
    expect(output['composition.dart'], contains('registry: registry'));
    // One set of runtimes, built once and shared: the reactive Models, the
    // transaction Models and the mutation targets all stand on it, so a write
    // and the read that observes it are the same stores (CAP-488).
    expect(
      output['composition.dart'],
      contains('Models buildModels(GeneratedModelRuntimes runtimes)'),
    );
    expect(output['local_sync.dart'], isNot(contains('buildTransactionScope')));
    expect(
      output['local_sync.dart'],
      allOf(
        contains('buildModelRuntimes(scope, registry: registry)'),
        contains('models: buildModels(runtimes)'),
        contains('transactionContexts: transactionContexts'),
        contains('scopeReconciler: scopeReconciler'),
      ),
    );

    expect(
      output['composition.dart'],
      isNot(contains('database.savepoint(action)')),
    );
    expect(output['composition.dart'], isNot(contains('await action()')));
    expect(output['composition.dart'], isNot(contains('validator.validate()')));
    expect(
      output['local_sync.dart'],
      contains(
        'extends LocalSyncRuntime<Models, TransactionModels, '
        'TransactionMutations>',
      ),
    );
    expect(output['local_sync.dart'], contains('Future<LocalSync> open'));
    expect(
      output['local_sync.dart'],
      contains('required DatabaseDriver driver'),
    );
    expect(output['local_sync.dart'], contains('required String clientId'));
    expect(output['local_sync.dart'], isNot(contains('ScopeKey')));
    expect(output['local_sync.dart'], contains('show UUID, FieldUpdate'));
    expect(
      output['local_sync.dart'],
      contains(
        'LocalSyncClientFailureObserver, LocalSyncMutations, '
        'LocalSyncMutationRejection, LocalSyncMutationRejectionId, '
        'LocalSyncRejectedOperation, LocalSyncRejectedScope, MutationOperation, '
        'LocalSyncOperationSnapshot, TransactionPrerequisites, TransactionMutationsInbox, '
        'LocalSyncPrerequisites, LocalSyncPrerequisiteFailure, '
        'LocalSyncPrerequisiteFailureId, LocalSyncFailedPrerequisite, '
        'LocalSyncPrerequisiteBinding, PrerequisiteInvocation;',
      ),
    );
    expect(
      output['local_sync.dart'],
      allOf(
        contains("export 'mutations.dart';"),
        contains("export 'downlink_changes.dart';"),
        isNot(contains('ScopeLease')),
        isNot(contains('ScopeBinding')),
        isNot(contains('late final Mutations mutate')),
      ),
    );
    expect(
      output['mutations.dart'],
      contains(
        'final class TransactionMutations {\n'
        '  const TransactionMutations(this._executor);\n\n'
        '  final MutationScopeExecutor<TransactionModels> _executor;\n'
        '}',
      ),
    );
    expect(
      output['local_sync.dart'],
      contains('required LocalSyncTransport transport'),
    );
    expect(output['local_sync.dart'], contains('UplinkController('));
    expect(output['local_sync.dart'], contains('MutationQueue('));
    expect(output['local_sync.dart'], contains('BatchExecutor('));
    expect(output['local_sync.dart'], contains('DownlinkWorker('));
    expect(output['local_sync.dart'], contains('DownlinkPageProcessor('));
    expect(output['local_sync.dart'], contains('processor: downlinkProcessor'));
    expect(
      output['local_sync.dart'],
      isNot(contains('LocalSyncScopeController')),
    );
    expect(
      output['local_sync.dart'],
      contains('retryPolicyFactory: () => RetryPolicy('),
    );
    expect(output['local_sync.dart'], isNot(contains('normalizeScopeKeys(')));
    expect(
      output['local_sync.dart'],
      isNot(contains('_registeredLocalSyncScopeModels')),
    );
    expect(
      output['local_sync.dart'],
      isNot(contains('downlinkProcessor.initializeScopes(')),
    );
    expect(output['local_sync.dart'], isNot(contains('Zone.current')));
    expect(
      output['local_sync.dart'],
      contains('LocalSyncClientFailureObserver? failureObserver'),
    );
    expect(
      RegExp(
        r'failureObserver: failureObserver',
      ).allMatches(output['local_sync.dart']!),
      hasLength(5),
    );
    expect(
      output['local_sync.dart'],
      contains('required LocalSyncTransport transport'),
    );
    // The codec needs no generated registry: field names are the schema, so
    // the wire is read straight off the Models the runtime already knows.
    expect(
      output['local_sync.dart'],
      allOf(
        contains('final codec = LocalSyncJsonCodec(registry: registry);'),
        contains('bindLegacyCheckpointScope: queue.bindLegacyCheckpointScope'),
      ),
    );
    expect(
      output['local_sync.dart'],
      isNot(contains('generatedLocalSyncProtocol')),
    );
    expect(output['local_sync.dart'], contains('LocalSyncLifecycle('));
    expect(output['local_sync.dart'], isNot(contains('lifecycle.start()')));
    expect(
      output['local_sync.dart'],
      contains('final scopeReconciler = ScopeReconciler('),
    );
    expect(
      output['local_sync.dart'],
      isNot(contains('scopeReconciler.start()')),
    );
    expect(output['local_sync.dart'], contains('lifecycle.close('));
  });

  // CAP-407 spec §2. The replica tolerates arrival order, so nothing it
  // generates may refuse a row for pointing at one that has not been claimed
  // yet.
  test('declares no foreign key anywhere in the generated DDL', () {
    final generated = emitDart(graph).values.join('\n');

    expect(generated, isNot(contains('FOREIGN KEY')));
    expect(generated, isNot(contains('REFERENCES')));
  });

  // Only the DDL changed. The declarations are still the metadata the
  // framework runs on — `onTargetDelete: delete` walks them — so they must
  // survive the constraint's removal byte for byte.
  test('leaves the relation metadata exactly as it was', () {
    final output = emitDart(graph);

    expect(
      output['models/star.dart'],
      contains('''
const starUserRelation = ModelRelationSchema(
  name: 'user',
  targetModel: 'User',
  localFields: ['userId'],
  referencedFields: ['id'],
  nullable: false,
  deleteOnTarget: true,
);

const starMomentRelation = ModelRelationSchema(
  name: 'moment',
  targetModel: 'Moment',
  localFields: ['momentId'],
  referencedFields: ['id'],
  nullable: false,
  deleteOnTarget: false,
);
'''),
    );
  });

  // CAP-437: the declaration is the key. A relation may be called anything —
  // the emitted `localFields` is what the definition listed, and the table it
  // sits on is unchanged by the naming either way.
  test('emits the declared key whatever the relation is called', () {
    const shelfSource = '''model Shelf {
  id UUID
  @@id(id)
}

model Page {
  id UUID
  spaceId UUID
  RELATION
  @@id(id)
}''';

    final named = emitDart(
      compileModelSources({
        'shelf.model': shelfSource.replaceFirst(
          'RELATION',
          'book Shelf @reference(via: [spaceId])',
        ),
      }),
    );
    final renamed = emitDart(
      compileModelSources({
        'shelf.model': shelfSource.replaceFirst(
          'RELATION',
          'shelf Shelf @reference(via: [spaceId])',
        ),
      }),
    );

    expect(
      named['models/page.dart'],
      contains('''
const pageBookRelation = ModelRelationSchema(
  name: 'book',
  targetModel: 'Shelf',
  localFields: ['spaceId'],
  referencedFields: ['id'],
  nullable: false,
  deleteOnTarget: false,
);
'''),
    );
    expect(renamed['models/page.dart'], contains("name: 'shelf',"));
    expect(renamed['models/page.dart'], contains("localFields: ['spaceId'],"));
    // Storage is untouched by the spelling: same columns, same identity, and
    // still no constraint.
    expect(renamed['storage/page.dart'], named['storage/page.dart']);
  });

  test('maps a composite key positionally onto the target identity', () {
    final output = emitDart(
      compileModelSources({
        'entry.model': '''model Star {
  userId UUID
  momentId UUID
  @@id(userId, momentId)
}

model StarTag {
  id UUID
  keeperId UUID
  pageId UUID
  star Star @reference(via: [keeperId, pageId], onTargetDelete: delete)
  @@id(id)
}''',
      }),
    );

    expect(
      output['models/star_tag.dart'],
      contains('''
  localFields: ['keeperId', 'pageId'],
  referencedFields: ['userId', 'momentId'],
'''),
    );
  });

  // CAP-437: the reverse half reaches the runtime as metadata and stops there.
  // It is what CAP-438 will read to nest a write under its root, and it must
  // never become a column, a wire field, or a migration step.
  test('emits the reverse half without giving it a column', () {
    final output = emitDart(
      compileModelSources({
        'shelf.model': '''model Shelf {
  id     UUID
  pages  Page[]
  cover  Cover?
  @@id(id)
}

model Page {
  id      UUID
  shelfId UUID
  shelf Shelf @reference(via: [shelfId], onTargetDelete: delete)
  @@id(id)
}

model Cover {
  shelfId UUID
  shelf Shelf @reference(via: [shelfId])
  @@id(shelfId)
}''',
      }),
    );

    expect(
      output['models/shelf.dart'],
      contains('''
const shelfPagesInverse = ModelInverseRelationSchema(
  name: 'pages',
  sourceModel: 'Page',
  reference: 'shelf',
  cardinality: ModelRelationCardinality.many,
);

const shelfCoverInverse = ModelInverseRelationSchema(
  name: 'cover',
  sourceModel: 'Cover',
  reference: 'shelf',
  cardinality: ModelRelationCardinality.optionalOne,
);
'''),
    );
    expect(
      output['models/shelf.dart'],
      contains('''
  inverseRelations: const [
    shelfPagesInverse,
    shelfCoverInverse,
  ],
'''),
    );
    // The table is the identity and nothing else: neither reverse half is a
    // column, and neither appears among the Model's fields or its wire shape.
    expect(
      output['storage/shelf.dart'],
      contains('''
      CREATE TABLE "model_shelf" (
        "id" TEXT NOT NULL,
        PRIMARY KEY ("id")
      )
'''),
    );
    for (final forbidden in ['pages', 'cover']) {
      expect(
        output['storage/shelf.dart'],
        isNot(contains(forbidden)),
        reason: forbidden,
      );
    }
  });

  test('keeps two relations between one pair of Models apart', () {
    final output = emitDart(
      compileModelSources({
        'link.model': '''model Moment {
  id            UUID
  outgoingLinks MomentLink[] @inverse("Source")
  incomingLinks MomentLink[] @inverse("Target")
  @@id(id)
}

model MomentLink {
  id       UUID
  sourceId UUID
  targetId UUID
  source Moment @reference("Source", via: [sourceId])
  target Moment @reference("Target", via: [targetId])
  @@id(id)
}''',
      }),
    );

    // Two references to the same Model, told apart by the shared name and by
    // the key each one stores.
    expect(
      output['models/moment_link.dart'],
      contains('''
const momentLinkSourceRelation = ModelRelationSchema(
  name: 'source',
  targetModel: 'Moment',
  relationName: 'Source',
  localFields: ['sourceId'],
  referencedFields: ['id'],
  nullable: false,
  deleteOnTarget: false,
);

const momentLinkTargetRelation = ModelRelationSchema(
  name: 'target',
  targetModel: 'Moment',
  relationName: 'Target',
  localFields: ['targetId'],
  referencedFields: ['id'],
  nullable: false,
  deleteOnTarget: false,
);
'''),
    );
    expect(
      output['models/moment.dart'],
      contains('''
const momentOutgoingLinksInverse = ModelInverseRelationSchema(
  name: 'outgoingLinks',
  sourceModel: 'MomentLink',
  reference: 'source',
  relationName: 'Source',
  cardinality: ModelRelationCardinality.many,
);

const momentIncomingLinksInverse = ModelInverseRelationSchema(
  name: 'incomingLinks',
  sourceModel: 'MomentLink',
  reference: 'target',
  relationName: 'Target',
  cardinality: ModelRelationCardinality.many,
);
'''),
    );
    // Two relations, one table, two ordinary columns — the names are framework
    // metadata and reach neither the DDL nor a constraint.
    expect(
      output['storage/moment_link.dart'],
      contains('''
      CREATE TABLE "model_moment_link" (
        "id" TEXT NOT NULL,
        "source_id" TEXT NOT NULL,
        "target_id" TEXT NOT NULL,
        PRIMARY KEY ("id")
      )
'''),
    );
    expect(output['storage/moment_link.dart'], isNot(contains('Source')));
  });

  test('contains no generated protocol or projection algorithms', () {
    final generated = emitDart(graph).values.join('\n');

    for (final forbidden in [
      'MutationReducer',
      'jsonEncode(',
      'jsonDecode(',
      'class TransactionValidator',
      'getInCurrentTransaction',
      'UplinkMutationNormalizer(',
      'batchId',
      'nextDelay(',
      'LocalSyncTransportFailure',
    ]) {
      expect(generated, isNot(contains(forbidden)), reason: forbidden);
    }
    for (final forbidden in [
      'package:drift/',
      'DriftCanonicalStore',
      'ModelStorageBinding',
      'MutationStorageBinding',
      'UplinkDatabaseBinding',
      'DownlinkDatabaseBinding',
      'GeneratedDatabase',
      '.g.dart',
    ]) {
      expect(generated, isNot(contains(forbidden)), reason: forbidden);
    }
  });
}
