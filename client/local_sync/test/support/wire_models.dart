import 'package:local_sync/local_sync.dart';

/// The wire-level Model fixtures shared by the change-decoder and envelope
/// codec suites: one Model covering every scalar, enum and list shape, and
/// one with a composite identity.

const spaceId = '550e8400-e29b-41d4-a716-446655440000';
const ownerId = 'b8bec29d-df16-4275-a978-338b228ce80c';
const momentId = '37ad6dcc-1d0c-4ae4-af76-6434521b7663';

AddressedModelChange address(Map<String, Object?> raw) =>
    AddressedModelChange(syncId: 101, raw: raw);

Map<String, Object?> spaceUpsert() => {
  'syncId': 101,
  'model': 'Space',
  'operation': 'upsert',
  'id': {'id': spaceId},
  'data': spaceData(),
};

Map<String, Object?> spaceDelete() => {
  'syncId': 101,
  'model': 'Space',
  'operation': 'delete',
  'id': {'id': spaceId},
};

Map<String, Object?> spaceData() => {
  'ownerId': ownerId,
  'name': 'Family',
  'isOpen': true,
  'memberCount': 3,
  'ratio': 1.5,
  'kind': 'group',
  'spaceOrder': [spaceId],
  'rankOrder': [1, 2],
  'eventTimes': ['2026-08-03T19:00:00Z'],
  'archivedAt': null,
};

final spaceSchema = ModelSchema<SpaceId>(
  name: 'Space',
  identity: const ['id'],
  fields: const [
    ModelFieldSchema(name: 'id', type: LocalScalarType.uuid, nullable: false),
    ModelFieldSchema(
      name: 'ownerId',
      type: LocalScalarType.uuid,
      nullable: false,
    ),
    ModelFieldSchema(
      name: 'name',
      type: LocalScalarType.string,
      nullable: false,
    ),
    ModelFieldSchema(
      name: 'isOpen',
      type: LocalScalarType.boolean,
      nullable: false,
    ),
    ModelFieldSchema(
      name: 'memberCount',
      type: LocalScalarType.int,
      nullable: false,
    ),
    ModelFieldSchema(
      name: 'ratio',
      type: LocalScalarType.float,
      nullable: false,
    ),
    ModelFieldSchema(
      name: 'archivedAt',
      type: LocalScalarType.dateTime,
      nullable: true,
    ),
    ModelFieldSchema(
      name: 'kind',
      type: LocalEnumType(
        name: 'TestSpaceKind',
        values: {'personal', 'group'},
        encode: encodeTestSpaceKind,
        decode: decodeTestSpaceKind,
      ),
      nullable: false,
    ),
    ModelFieldSchema(
      name: 'spaceOrder',
      type: LocalScalarListType(LocalScalarType.uuid),
      nullable: false,
    ),
    ModelFieldSchema(
      name: 'rankOrder',
      type: LocalScalarListType(LocalScalarType.int),
      nullable: false,
    ),
    ModelFieldSchema(
      name: 'eventTimes',
      type: LocalScalarListType(LocalScalarType.dateTime),
      nullable: false,
    ),
  ],
  uniqueConstraints: const [],
  relations: const [],
  createId: (parts) => SpaceId(parts['id']! as UUID),
);

final starSchema = ModelSchema<StarId>(
  name: 'Star',
  identity: const ['userId', 'momentId'],
  fields: const [
    ModelFieldSchema(
      name: 'userId',
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
  relations: const [],
  createId: (parts) =>
      StarId(parts['userId']! as UUID, parts['momentId']! as UUID),
);

final class SpaceId extends ModelId {
  const SpaceId(this.id);
  final UUID id;
  @override
  Map<String, Object> get components => {'id': id};
  @override
  bool operator ==(Object other) => other is SpaceId && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

final class StarId extends ModelId {
  const StarId(this.userId, this.momentId);
  final UUID userId;
  final UUID momentId;
  @override
  Map<String, Object> get components => {
    'userId': userId,
    'momentId': momentId,
  };
  @override
  bool operator ==(Object other) =>
      other is StarId && other.userId == userId && other.momentId == momentId;
  @override
  int get hashCode => Object.hash(userId, momentId);
}

UUID uuid(String value) => UUID.withValidation(value);

enum TestSpaceKind { personal, group }

String encodeTestSpaceKind(Object value) => (value as TestSpaceKind).name;
Object decodeTestSpaceKind(String wire) => TestSpaceKind.values.byName(wire);
