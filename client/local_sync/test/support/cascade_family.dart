import 'package:local_sync/local_sync.dart';
import 'package:local_sync_database/local_sync_database.dart';

/// A family of Models with declared references, for the tests that walk the
/// graph rather than one table.
///
/// The shape is the product's own, reduced to what the walk can get wrong:
/// `FamilySpace -> FamilyMoment -> FamilyPhoto` gives depth, `FamilyTag` hangs
/// off `FamilyMoment` imposing neither rule so both walks must step over it,
/// `FamilyMember` is a composite-identity child of `FamilySpace`, and
/// `FamilyStar` is the ordinary association — two plain references to two
/// different Models, imposing nothing.
///
/// `FamilyPhoto.key` is the family's readiness key, and `FamilyCrop` hangs off
/// `FamilyPhoto` so the drop's closure has a depth-2 chain to walk. Which
/// writes share fate is no longer read off a reference at all: it is settled by
/// the name at the call site, one named act at a time (CAP-444).
PrerequisiteInvocation remoteObject(String key) =>
    PrerequisiteInvocation(name: 'RemoteObject', arguments: {'key': key});

final class FamilySpaceId extends ModelId {
  const FamilySpaceId(this.value);

  final UUID value;

  @override
  Map<String, Object> get components => {'id': value};

  @override
  bool operator ==(Object other) =>
      other is FamilySpaceId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'FamilySpaceId($value)';
}

final class FamilyMomentId extends ModelId {
  const FamilyMomentId(this.value);

  final UUID value;

  @override
  Map<String, Object> get components => {'id': value};

  @override
  bool operator ==(Object other) =>
      other is FamilyMomentId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'FamilyMomentId($value)';
}

final class FamilyPhotoId extends ModelId {
  const FamilyPhotoId(this.value);

  final UUID value;

  @override
  Map<String, Object> get components => {'id': value};

  @override
  bool operator ==(Object other) =>
      other is FamilyPhotoId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  // Deliberately no toString: generated ModelIds have none, and anything that
  // keys rows by their id object would collapse two photos into one.
}

final class FamilyCropId extends ModelId {
  const FamilyCropId(this.value);

  final UUID value;

  @override
  Map<String, Object> get components => {'id': value};

  @override
  bool operator ==(Object other) =>
      other is FamilyCropId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'FamilyCropId($value)';
}

final class FamilyTagId extends ModelId {
  const FamilyTagId(this.value);

  final UUID value;

  @override
  Map<String, Object> get components => {'id': value};

  @override
  bool operator ==(Object other) =>
      other is FamilyTagId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'FamilyTagId($value)';
}

final class FamilyStarId extends ModelId {
  const FamilyStarId(this.value);

  final UUID value;

  @override
  Map<String, Object> get components => {'id': value};

  @override
  bool operator ==(Object other) =>
      other is FamilyStarId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'FamilyStarId($value)';
}

final class FamilyMemberId extends ModelId {
  const FamilyMemberId({required this.spaceId, required this.userId});

  final UUID spaceId;
  final UUID userId;

  @override
  Map<String, Object> get components => {'spaceId': spaceId, 'userId': userId};

  @override
  bool operator ==(Object other) =>
      other is FamilyMemberId &&
      other.spaceId == spaceId &&
      other.userId == userId;

  @override
  int get hashCode => Object.hash(spaceId, userId);

  @override
  String toString() => 'FamilyMemberId($spaceId, $userId)';
}

const familyMomentSpaceRelation = ModelRelationSchema(
  name: 'space',
  targetModel: 'FamilySpace',
  localFields: ['spaceId'],
  referencedFields: ['id'],
  nullable: false,
  deleteOnTarget: true,
);

const familyPhotoMomentRelation = ModelRelationSchema(
  name: 'moment',
  targetModel: 'FamilyMoment',
  localFields: ['momentId'],
  referencedFields: ['id'],
  nullable: false,
  deleteOnTarget: true,
);

/// Declared, but imposing neither rule: the index carries it, the cascade
/// walk must not follow it.
const familyTagMomentRelation = ModelRelationSchema(
  name: 'moment',
  targetModel: 'FamilyMoment',
  localFields: ['momentId'],
  referencedFields: ['id'],
  nullable: false,
  deleteOnTarget: false,
);

/// The ordinary association: two plain references, imposing nothing. A cascade
/// steps over both.
const familyStarSpaceRelation = ModelRelationSchema(
  name: 'space',
  targetModel: 'FamilySpace',
  localFields: ['spaceId'],
  referencedFields: ['id'],
  nullable: false,
  deleteOnTarget: false,
);

const familyStarMomentRelation = ModelRelationSchema(
  name: 'moment',
  targetModel: 'FamilyMoment',
  localFields: ['momentId'],
  referencedFields: ['id'],
  nullable: false,
  deleteOnTarget: false,
);

const familyMemberSpaceRelation = ModelRelationSchema(
  name: 'space',
  targetModel: 'FamilySpace',
  localFields: ['spaceId'],
  referencedFields: ['id'],
  nullable: false,
  deleteOnTarget: true,
);

final familySpaceSchema = ModelSchema<FamilySpaceId>(
  name: 'FamilySpace',
  identity: const ['id'],
  fields: const [
    ModelFieldSchema(name: 'id', type: LocalScalarType.uuid, nullable: false),
    ModelFieldSchema(
      name: 'name',
      type: LocalScalarType.string,
      nullable: false,
    ),
  ],
  uniqueConstraints: const [],
  relations: const [],
  createId: (components) => FamilySpaceId(components['id']! as UUID),
);

final familyMomentSchema = ModelSchema<FamilyMomentId>(
  name: 'FamilyMoment',
  identity: const ['id'],
  fields: const [
    ModelFieldSchema(name: 'id', type: LocalScalarType.uuid, nullable: false),
    ModelFieldSchema(
      name: 'spaceId',
      type: LocalScalarType.uuid,
      nullable: false,
    ),
    ModelFieldSchema(
      name: 'caption',
      type: LocalScalarType.string,
      nullable: true,
    ),
  ],
  uniqueConstraints: const [],
  relations: const [familyMomentSpaceRelation],
  createId: (components) => FamilyMomentId(components['id']! as UUID),
);

final familyPhotoSchema = ModelSchema<FamilyPhotoId>(
  name: 'FamilyPhoto',
  identity: const ['id'],
  fields: const [
    ModelFieldSchema(name: 'id', type: LocalScalarType.uuid, nullable: false),
    ModelFieldSchema(
      name: 'momentId',
      type: LocalScalarType.uuid,
      nullable: false,
    ),
    ModelFieldSchema(
      name: 'key',
      type: LocalScalarType.string,
      nullable: false,
      prerequisite: ModelPrerequisiteRequirementSchema(
        name: 'RemoteObject',
        arguments: {'key': 'key'},
      ),
    ),
  ],
  uniqueConstraints: const [],
  relations: const [familyPhotoMomentRelation],
  createId: (components) => FamilyPhotoId(components['id']! as UUID),
);

const familyCropPhotoRelation = ModelRelationSchema(
  name: 'photo',
  targetModel: 'FamilyPhoto',
  localFields: ['photoId'],
  referencedFields: ['id'],
  nullable: false,
  deleteOnTarget: true,
);

final familyCropSchema = ModelSchema<FamilyCropId>(
  name: 'FamilyCrop',
  identity: const ['id'],
  fields: const [
    ModelFieldSchema(name: 'id', type: LocalScalarType.uuid, nullable: false),
    ModelFieldSchema(
      name: 'photoId',
      type: LocalScalarType.uuid,
      nullable: false,
    ),
  ],
  uniqueConstraints: const [],
  relations: const [familyCropPhotoRelation],
  createId: (components) => FamilyCropId(components['id']! as UUID),
);

final familyTagSchema = ModelSchema<FamilyTagId>(
  name: 'FamilyTag',
  identity: const ['id'],
  fields: const [
    ModelFieldSchema(name: 'id', type: LocalScalarType.uuid, nullable: false),
    ModelFieldSchema(
      name: 'momentId',
      type: LocalScalarType.uuid,
      nullable: false,
    ),
  ],
  uniqueConstraints: const [],
  relations: const [familyTagMomentRelation],
  createId: (components) => FamilyTagId(components['id']! as UUID),
);

final familyStarSchema = ModelSchema<FamilyStarId>(
  name: 'FamilyStar',
  identity: const ['id'],
  fields: const [
    ModelFieldSchema(name: 'id', type: LocalScalarType.uuid, nullable: false),
    ModelFieldSchema(
      name: 'spaceId',
      type: LocalScalarType.uuid,
      nullable: false,
    ),
    ModelFieldSchema(
      name: 'momentId',
      type: LocalScalarType.uuid,
      nullable: false,
    ),
  ],
  uniqueConstraints: const [],
  relations: const [familyStarSpaceRelation, familyStarMomentRelation],
  createId: (components) => FamilyStarId(components['id']! as UUID),
);

final familyMemberSchema = ModelSchema<FamilyMemberId>(
  name: 'FamilyMember',
  identity: const ['spaceId', 'userId'],
  fields: const [
    ModelFieldSchema(
      name: 'spaceId',
      type: LocalScalarType.uuid,
      nullable: false,
    ),
    ModelFieldSchema(
      name: 'userId',
      type: LocalScalarType.uuid,
      nullable: false,
    ),
    ModelFieldSchema(
      name: 'role',
      type: LocalScalarType.string,
      nullable: false,
    ),
  ],
  uniqueConstraints: const [],
  relations: const [familyMemberSpaceRelation],
  createId: (components) => FamilyMemberId(
    spaceId: components['spaceId']! as UUID,
    userId: components['userId']! as UUID,
  ),
);

ModelDatabaseDescriptor<I> _descriptor<I extends ModelId>(
  ModelSchema<I> schema,
  String tableName,
) => ModelDatabaseDescriptor<I>(
  schema: schema,
  tableName: tableName,
  columns: {for (final field in schema.fields) field.name: field.name},
);

final familySpaceDescriptor = _descriptor(familySpaceSchema, 'family_space');
final familySpaceBeforeDescriptor = _descriptor(
  familySpaceSchema,
  'family_space_before',
);
final familyMomentDescriptor = _descriptor(familyMomentSchema, 'family_moment');
final familyMomentBeforeDescriptor = _descriptor(
  familyMomentSchema,
  'family_moment_before',
);
final familyPhotoDescriptor = _descriptor(familyPhotoSchema, 'family_photo');
final familyPhotoBeforeDescriptor = _descriptor(
  familyPhotoSchema,
  'family_photo_before',
);
final familyCropDescriptor = _descriptor(familyCropSchema, 'family_crop');
final familyCropBeforeDescriptor = _descriptor(
  familyCropSchema,
  'family_crop_before',
);
final familyStarDescriptor = _descriptor(familyStarSchema, 'family_star');
final familyStarBeforeDescriptor = _descriptor(
  familyStarSchema,
  'family_star_before',
);
final familyTagDescriptor = _descriptor(familyTagSchema, 'family_tag');
final familyTagBeforeDescriptor = _descriptor(
  familyTagSchema,
  'family_tag_before',
);
final familyMemberDescriptor = _descriptor(familyMemberSchema, 'family_member');
final familyMemberBeforeDescriptor = _descriptor(
  familyMemberSchema,
  'family_member_before',
);

DatabaseStatement _createTable(ModelDatabaseDescriptor<ModelId> descriptor) {
  final schema = descriptor.schema;
  final columns = schema.fields
      .map(
        (field) =>
            '"${descriptor.column(field.name)}" TEXT'
            '${field.nullable ? '' : ' NOT NULL'}',
      )
      .join(', ');
  final primaryKey = schema.identity
      .map((field) => '"${descriptor.column(field)}"')
      .join(', ');
  return DatabaseStatement(
    sql:
        'CREATE TABLE "${descriptor.tableName}" '
        '($columns, PRIMARY KEY ($primaryKey))',
  );
}

final familyModelStatements = <DatabaseStatement>[
  for (final descriptor in <ModelDatabaseDescriptor<ModelId>>[
    familySpaceDescriptor,
    familySpaceBeforeDescriptor,
    familyMomentDescriptor,
    familyMomentBeforeDescriptor,
    familyPhotoDescriptor,
    familyPhotoBeforeDescriptor,
    familyCropDescriptor,
    familyCropBeforeDescriptor,
    familyStarDescriptor,
    familyStarBeforeDescriptor,
    familyTagDescriptor,
    familyTagBeforeDescriptor,
    familyMemberDescriptor,
    familyMemberBeforeDescriptor,
  ])
    _createTable(descriptor),
];

/// The registry the family's tests walk, plus each entry by name so a test can
/// write a row without looking it up.
final class FamilyRegistry {
  FamilyRegistry(LocalDatabaseScope database)
    : space = _entry(
        database,
        familySpaceSchema,
        familySpaceDescriptor,
        familySpaceBeforeDescriptor,
      ),
      moment = _entry(
        database,
        familyMomentSchema,
        familyMomentDescriptor,
        familyMomentBeforeDescriptor,
      ),
      photo = _entry(
        database,
        familyPhotoSchema,
        familyPhotoDescriptor,
        familyPhotoBeforeDescriptor,
      ),
      crop = _entry(
        database,
        familyCropSchema,
        familyCropDescriptor,
        familyCropBeforeDescriptor,
      ),
      tag = _entry(
        database,
        familyTagSchema,
        familyTagDescriptor,
        familyTagBeforeDescriptor,
      ),
      star = _entry(
        database,
        familyStarSchema,
        familyStarDescriptor,
        familyStarBeforeDescriptor,
      ),
      member = _entry(
        database,
        familyMemberSchema,
        familyMemberDescriptor,
        familyMemberBeforeDescriptor,
      );

  final TypedModelRegistryEntry<FamilySpaceId> space;
  final TypedModelRegistryEntry<FamilyMomentId> moment;
  final TypedModelRegistryEntry<FamilyPhotoId> photo;
  final TypedModelRegistryEntry<FamilyCropId> crop;
  final TypedModelRegistryEntry<FamilyTagId> tag;
  final TypedModelRegistryEntry<FamilyStarId> star;
  final TypedModelRegistryEntry<FamilyMemberId> member;

  late final ModelRegistry registry = ModelRegistry([
    space,
    moment,
    photo,
    crop,
    tag,
    star,
    member,
  ]);

  static TypedModelRegistryEntry<I> _entry<I extends ModelId>(
    LocalDatabaseScope database,
    ModelSchema<I> schema,
    ModelDatabaseDescriptor<I> main,
    ModelDatabaseDescriptor<I> before,
  ) => TypedModelRegistryEntry<I>(
    schema: schema,
    canonical: SqlCanonicalStore<I>(database: database, descriptor: main),
    before: BeforeImageStore<I>(database: database, main: main, before: before),
    mutations: SqlMutationStore<I>(database: database, schema: schema),
  );
}

/// The write path over the same tables, assembled the way generated code
/// assembles it: runtimes built per Model, all handed the one registry.
final class FamilyRuntimes {
  FamilyRuntimes(this._database, this._registry)
    : space = _runtime(
        _database,
        _registry,
        familySpaceDescriptor,
        familySpaceBeforeDescriptor,
      ),
      moment = _runtime(
        _database,
        _registry,
        familyMomentDescriptor,
        familyMomentBeforeDescriptor,
      ),
      photo = _runtime(
        _database,
        _registry,
        familyPhotoDescriptor,
        familyPhotoBeforeDescriptor,
      ),
      crop = _runtime(
        _database,
        _registry,
        familyCropDescriptor,
        familyCropBeforeDescriptor,
      ),
      tag = _runtime(
        _database,
        _registry,
        familyTagDescriptor,
        familyTagBeforeDescriptor,
      ),
      star = _runtime(
        _database,
        _registry,
        familyStarDescriptor,
        familyStarBeforeDescriptor,
      ),
      member = _runtime(
        _database,
        _registry,
        familyMemberDescriptor,
        familyMemberBeforeDescriptor,
      );

  final LocalDatabaseScope _database;
  final ModelRegistry _registry;

  final ModelRuntime<FamilySpaceId> space;
  final ModelRuntime<FamilyMomentId> moment;
  final ModelRuntime<FamilyPhotoId> photo;
  final ModelRuntime<FamilyCropId> crop;
  final ModelRuntime<FamilyTagId> tag;
  final ModelRuntime<FamilyStarId> star;
  final ModelRuntime<FamilyMemberId> member;

  /// What generation hands the executor: one queued write path per Model, by
  /// name — where a named act applies its returned slots.
  Map<String, MutationTarget> get mutationTargets => Map.fromEntries([
    mutationTarget('FamilySpace', space.queued),
    mutationTarget('FamilyMoment', moment.queued),
    mutationTarget('FamilyPhoto', photo.queued),
    mutationTarget('FamilyCrop', crop.queued),
    mutationTarget('FamilyTag', tag.queued),
    mutationTarget('FamilyStar', star.queued),
    mutationTarget('FamilyMember', member.queued),
  ]);

  late final TransactionContextFactory<
    FamilyTransactionModels,
    FamilyTransactionMutations
  >
  _contexts = TransactionContextFactory(
    database: _database,
    registry: _registry,
    targets: mutationTargets,
    buildModels: (context) => FamilyTransactionModels(
      space: _bound(space, context),
      moment: _bound(moment, context),
      photo: _bound(photo, context),
      crop: _bound(crop, context),
      tag: _bound(tag, context),
      star: _bound(star, context),
      member: _bound(member, context),
    ),
    buildTransactionScopes: (context) =>
        FateAwareScopeWriter(store: ScopeStore(_database), context: context),
    buildMutationScopes: (context) =>
        FateAwareScopeWriter(store: ScopeStore(_database), context: context),
    buildMutations: FamilyTransactionMutations.new,
  );

  late final TransactionExecutor<
    FamilyTransactionModels,
    FamilyTransactionMutations
  >
  executor = TransactionExecutor(database: _database, contexts: _contexts);

  Future<R> transaction<R>(
    Future<R> Function(
      LocalSyncTransaction<FamilyTransactionModels, FamilyTransactionMutations>
      tx,
    )
    action,
  ) => executor.run(action);

  /// Commits to this device only — no record, no queue row, no wire.
  Future<void> write(
    Future<void> Function(FamilyTransactionModels models) action,
  ) => transaction((tx) => action(tx.models));

  /// Applies a prebuilt record through the named-act path — the shape a
  /// generated Mutation method's `record:` callback produces.
  Future<void> apply(
    MutationRecord record, {
    Future<void> Function(FamilyTransactionModels models)? companions,
  }) => transaction((tx) => tx.mutate.apply(record, companions: companions));

  /// Applies one named act over these Models — the wire boundary, spelled the
  /// way a call site spells it (CAP-488).
  Future<void> mutate(
    String name,
    List<ModelOperation> operations, {
    List<SlotBinding> bindings = const [],
    Future<void> Function(FamilyTransactionModels models)? companions,
  }) => transaction(
    (tx) => tx.mutate.run(
      name: name,
      build: (mutation) async {
        await companions?.call(mutation.models);
        return (operations: operations);
      },
      record: (result) => familyMutationRecord(
        name: name,
        operations: result.operations,
        bindings: bindings,
      ),
    ),
  );

  /// A deliberate no-op act: its callback returns null after its companions
  /// ran, so record and companions roll back together.
  Future<void> mutateNothing(
    String name, {
    Future<void> Function(FamilyTransactionModels models)? companions,
  }) => transaction((tx) => tx.mutate.nothing(name, companions: companions));

  static FamilyTransactionModel<I> _bound<I extends ModelId>(
    ModelRuntime<I> runtime,
    TransactionFateContext context,
  ) => FamilyTransactionModel<I>(
    reader: runtime.reader,
    writer: TransactionModelWriter<I>(
      context: context,
      direct: runtime.direct,
      queued: runtime.queued,
    ),
  );

  static ModelRuntime<I> _runtime<I extends ModelId>(
    LocalDatabaseScope database,
    ModelRegistry registry,
    ModelDatabaseDescriptor<I> main,
    ModelDatabaseDescriptor<I> before,
  ) => ModelRuntime<I>(
    database: database,
    descriptor: main,
    beforeDescriptor: before,
    registry: registry,
  );
}

final class FamilyTransactionMutations {
  const FamilyTransactionMutations(this._executor);

  final MutationScopeExecutor<FamilyTransactionModels> _executor;

  Future<void> apply(
    MutationRecord record, {
    Future<void> Function(FamilyTransactionModels models)? companions,
  }) => _executor.run(
    name: record.name,
    build: (mutation) async {
      await companions?.call(mutation.models);
      return (record: record);
    },
    record: (result) => result.record,
  );

  Future<void> run<R extends Object>({
    required String name,
    required Future<R?> Function(
      LocalSyncMutationScope<FamilyTransactionModels> mutation,
    )
    build,
    required MutationRecord Function(R result) record,
  }) => _executor.run(name: name, build: build, record: record);

  Future<void> nothing(
    String name, {
    Future<void> Function(FamilyTransactionModels models)? companions,
  }) => _executor.run<({List<ModelOperation> operations})>(
    name: name,
    build: (mutation) async {
      await companions?.call(mutation.models);
      return null;
    },
    record: (result) =>
        familyMutationRecord(name: name, operations: result.operations),
  );
}

/// One Model as a write callback holds it: reads and writes inside the
/// callback's own transaction, the shape generated code emits.
final class FamilyTransactionModel<I extends ModelId> {
  const FamilyTransactionModel({required this.reader, required this.writer});

  final TransactionModelReader<I> reader;
  final ModelWriter<I> writer;

  /// The row as it stands INSIDE this transaction — which is the whole point
  /// of reading here rather than before the act opened (CAP-488).
  Future<ModelRecord<I>?> get(I id) => reader.getInCurrentTransaction(id);

  Future<void> create(I id, Map<String, Object?> values) =>
      writer.create(id, values);

  Future<void> update(I id, Map<String, Object?> patch) =>
      writer.update(id, patch);

  Future<void> delete(I id) => writer.delete(id);
}

/// The family's Models as a write callback holds them.
final class FamilyTransactionModels {
  const FamilyTransactionModels({
    required this.space,
    required this.moment,
    required this.photo,
    required this.crop,
    required this.tag,
    required this.star,
    required this.member,
  });

  final FamilyTransactionModel<FamilySpaceId> space;
  final FamilyTransactionModel<FamilyMomentId> moment;
  final FamilyTransactionModel<FamilyPhotoId> photo;
  final FamilyTransactionModel<FamilyCropId> crop;
  final FamilyTransactionModel<FamilyTagId> tag;
  final FamilyTransactionModel<FamilyStarId> star;
  final FamilyTransactionModel<FamilyMemberId> member;
}

UUID familyUuid(int value) => UUID.withValidation(
  '7f1c9a20-0000-4000-8000-${value.toString().padLeft(12, '0')}',
);
MutationRecord familyMutationRecord({
  required String name,
  required Iterable<ModelOperation> operations,
  Iterable<SlotBinding> bindings = const [],
  Iterable<MutationSequenceSelector> sequenceSelectors = const [],
}) => MutationRecord(
  name: name,
  slotOperations: [
    for (final (index, operation) in operations.indexed)
      MutationSlotOperation(
        slotName: 'wire$index',
        operation: operation,
        allowedPatchFields: operation is ModelUpdateOperation
            ? operation.patch.keys
            : null,
      ),
  ],
  bindings: bindings,
  sequenceSelectors: sequenceSelectors,
);
