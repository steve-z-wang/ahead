import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

void main() {
  test('identity is canonical across argument order and keeps scalar type', () {
    final uuid = UUID.withValidation('11111111-1111-4111-8111-111111111111');
    final left = PrerequisiteInvocation(
      name: 'RemoteBlob',
      arguments: {'owner': 'person', 'key': uuid},
    );
    final reordered = PrerequisiteInvocation(
      name: 'RemoteBlob',
      arguments: {'key': uuid, 'owner': 'person'},
    );
    final stringKey = PrerequisiteInvocation(
      name: 'RemoteBlob',
      arguments: {'key': uuid.uuid, 'owner': 'person'},
    );

    expect(left, reordered);
    expect(left.identity, reordered.identity);
    expect(left, isNot(stringKey));
  });

  test('an unknown handler is invalid durable prerequisite data', () async {
    final invocation = PrerequisiteInvocation(
      name: 'Missing',
      arguments: {'key': 'value'},
    );

    await expectLater(
      PrerequisiteHandlerRegistry(const {}).dispatch(invocation),
      throwsA(isA<UplinkDataException>()),
    );
  });
}
