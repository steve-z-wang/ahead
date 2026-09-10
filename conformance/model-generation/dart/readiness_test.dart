import 'package:local_sync/local_sync.dart';
import 'package:local_sync_conformance/local_sync_conformance.dart';
import 'package:test/test.dart';

void main() {
  test('the generated handler registry decodes typed arguments', () async {
    String? received;
    final registry = buildPrerequisiteHandlers(
      LocalSyncPrerequisiteHandlers(
        remoteLabel: ({required key}) async {
          received = key;
          return PrerequisiteAttemptResult.ready;
        },
      ),
    );

    final result = await registry.dispatch(
      PrerequisiteInvocation(
        name: 'RemoteLabel',
        arguments: const {'key': 'conformance/ready'},
      ),
    );

    expect(result, PrerequisiteAttemptResult.ready);
    expect(received, 'conformance/ready');
  });
}
