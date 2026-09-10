import 'dart:convert';

import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

import '../support/fake_protocol_codec.dart';
import '../support/fake_uplink_transport.dart';

void main() {
  const codec = FakeProtocolCodec();

  test('retries the exact frozen bytes and returns a typed result', () async {
    final transport = FakeUplinkTransport([
      const LocalSyncRetryableTransportFailure('unavailable', status: 503),
      encodeBytes({'requiredSyncId': 7, 'rejections': <Object>[]}),
    ]);
    final executor = BatchExecutor(
      codec: codec,
      transport: transport,
      retryPolicy: RetryPolicy(randomDouble: () => 0),
      sleep: (_) async {},
    );

    final result = await executor.execute(batch(9));

    expect(transport.bodies, hasLength(2));
    expect(transport.bodies[0], transport.bodies[1]);
    expect(result?.batchSequence, 9);
    expect(result?.legacyPrincipalCheckpoint.syncId, 7);
  });

  test('a terminal transport failure remains terminal', () async {
    final failures = <LocalSyncClientFailure>[];
    final executor = BatchExecutor(
      codec: codec,
      transport: FakeUplinkTransport([
        const LocalSyncTerminalTransportFailure('forbidden', status: 403),
      ]),
      retryPolicy: RetryPolicy(randomDouble: () => 0),
      sleep: (_) async {},
      failureObserver: failures.add,
    );

    await expectLater(
      executor.execute(batch(1)),
      throwsA(isA<LocalSyncTerminalException>()),
    );
    expect(failures, isEmpty);
  });

  test(
    'reports one unexpected retry episode and resets after success',
    () async {
      final firstError = StateError('first');
      final secondError = StateError('second');
      final failures = <LocalSyncClientFailure>[];
      final transport = FakeUplinkTransport([
        firstError,
        firstError,
        encodeBytes({'requiredSyncId': 7, 'rejections': <Object>[]}),
        secondError,
        encodeBytes({'requiredSyncId': 8, 'rejections': <Object>[]}),
      ]);
      final executor = BatchExecutor(
        codec: codec,
        transport: transport,
        retryPolicy: RetryPolicy(randomDouble: () => 0),
        sleep: (_) async {},
        failureObserver: failures.add,
      );

      await executor.execute(batch(1));
      await executor.execute(batch(2));

      expect(failures, hasLength(2));
      expect(failures.first.error, same(firstError));
      expect(failures.last.error, same(secondError));
      expect(
        failures.map((failure) => failure.boundary),
        everyElement(LocalSyncClientFailureBoundary.uplink),
      );
      expect(
        failures.map((failure) => failure.fate),
        everyElement(LocalSyncClientFailureFate.retrying),
      );
    },
  );

  test('classified transport failures are not observed', () async {
    final failures = <LocalSyncClientFailure>[];
    final executor = BatchExecutor(
      codec: codec,
      transport: FakeUplinkTransport([
        const LocalSyncRetryableTransportFailure('weather'),
        encodeBytes({'requiredSyncId': 7, 'rejections': <Object>[]}),
      ]),
      retryPolicy: RetryPolicy(randomDouble: () => 0),
      sleep: (_) async {},
      failureObserver: failures.add,
    );

    await executor.execute(batch(1));

    expect(failures, isEmpty);
  });

  test('a throwing observer cannot change retry or result', () async {
    final executor = BatchExecutor(
      codec: codec,
      transport: FakeUplinkTransport([
        StateError('unknown'),
        encodeBytes({'requiredSyncId': 7, 'rejections': <Object>[]}),
      ]),
      retryPolicy: RetryPolicy(randomDouble: () => 0),
      sleep: (_) async {},
      failureObserver: (_) => throw StateError('observer'),
    );

    final result = await executor.execute(batch(1));

    expect(result?.legacyPrincipalCheckpoint.syncId, 7);
  });

  test('close cancels the request in flight', () async {
    final transport = FakeUplinkTransport([
      FakeUplinkTransport.blockUntilCancelled,
    ]);
    final executor = BatchExecutor(
      codec: codec,
      transport: transport,
      retryPolicy: RetryPolicy(randomDouble: () => 0),
      sleep: (_) async {},
    );

    final running = executor.execute(batch(1));
    await Future<void>.delayed(Duration.zero);
    await executor.close();

    expect(await running, isNull);
    expect(transport.cancelCalls, 1);
  });
}

UplinkBatch batch(int sequence) {
  final operation = StoredMutationOperation(
    mutationOrdinal: 1,
    position: 0,
    model: 'Test',
    identityJson: '{"id":"550e8400-e29b-41d4-a716-446655440000"}',
    operation: 'update',
    valuesJson: jsonEncode({'name': 'one'}),
    isUplink: true,
  );
  return UplinkBatch(
    clientId: '5d6c1f20-9105-4f7e-89d7-163fa5dcbb84',
    batchSequence: sequence,
    mutations: [operation],
    records: {
      1: const StoredMutation(
        ordinal: 1,
        name: 'UpdateTest',
        legacyFifo: false,
      ),
    },
  );
}
