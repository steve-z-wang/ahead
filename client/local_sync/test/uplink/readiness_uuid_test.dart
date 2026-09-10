import 'dart:convert';

import 'package:local_sync/local_sync.dart';
import 'package:local_sync/src/uplink/queued_mutation.dart';
import 'package:test/test.dart';

import '../support/never_registry_entry.dart';

void main() {
  const blobId = '018f6c2a-9074-7d2d-9c34-92e724bbdc56';

  test('create derives one typed invocation from the carried field', () {
    final invocations = prerequisiteInvocationsOf(_registry, [
      _operation(MutationOperation.create, {'blobId': blobId}),
    ]).toList();

    expect(invocations, hasLength(1));
    expect(invocations.single.name, 'RemoteBlob');
    expect(invocations.single.arguments, {'key': UUID.withValidation(blobId)});
  });

  test('update derives only fields actually named by the patch', () {
    expect(
      prerequisiteInvocationsOf(_registry, [
        _operation(MutationOperation.update, {'caption': 'kept'}),
      ]),
      isEmpty,
    );
    expect(
      prerequisiteInvocationsOf(_registry, [
        _operation(MutationOperation.update, {'blobId': blobId}),
      ]).single.name,
      'RemoteBlob',
    );
  });

  test('delete and nullable null contribute no invocation', () {
    expect(
      prerequisiteInvocationsOf(_registry, [
        _operation(MutationOperation.delete, const {}),
        _operation(MutationOperation.update, {'optionalBlobId': null}),
      ]),
      isEmpty,
    );
  });

  test('identical invocations deduplicate but scalar types stay distinct', () {
    final invocations = prerequisiteInvocationsOf(_registry, [
      _operation(MutationOperation.create, {
        'blobId': blobId,
        'optionalBlobId': blobId,
        'stringKey': blobId,
      }),
    ]).toList();

    expect(invocations, hasLength(2));
    expect(invocations.map((item) => item.name), {
      'RemoteBlob',
      'RemoteString',
    });
  });
}

final _registry = ModelRegistry([
  NeverModelRegistryEntry(_blobReferenceSchema),
]);

StoredMutationOperation _operation(
  MutationOperation operation,
  Map<String, Object?> values,
) => StoredMutationOperation(
  mutationOrdinal: 1,
  position: 0,
  model: 'BlobReference',
  identityJson: jsonEncode({'id': '018f6c2a-9074-7d2d-9c34-92e724bbdc56'}),
  operation: operation.name,
  valuesJson: jsonEncode(values),
  isUplink: true,
);

final _blobReferenceSchema = ModelSchema<ModelId>(
  name: 'BlobReference',
  identity: const ['id'],
  fields: const [
    ModelFieldSchema(name: 'id', type: LocalScalarType.uuid, nullable: false),
    ModelFieldSchema(
      name: 'blobId',
      type: LocalScalarType.uuid,
      nullable: false,
      prerequisite: ModelPrerequisiteRequirementSchema(
        name: 'RemoteBlob',
        arguments: {'key': 'blobId'},
      ),
    ),
    ModelFieldSchema(
      name: 'optionalBlobId',
      type: LocalScalarType.uuid,
      nullable: true,
      prerequisite: ModelPrerequisiteRequirementSchema(
        name: 'RemoteBlob',
        arguments: {'key': 'optionalBlobId'},
      ),
    ),
    ModelFieldSchema(
      name: 'stringKey',
      type: LocalScalarType.string,
      nullable: true,
      prerequisite: ModelPrerequisiteRequirementSchema(
        name: 'RemoteString',
        arguments: {'key': 'stringKey'},
      ),
    ),
    ModelFieldSchema(
      name: 'caption',
      type: LocalScalarType.string,
      nullable: true,
    ),
  ],
  uniqueConstraints: const [],
  relations: const [],
  createId: (_) => throw StateError('identity decoding is unused'),
);
