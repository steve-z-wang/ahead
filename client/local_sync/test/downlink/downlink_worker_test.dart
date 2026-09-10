import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

import '../support/fake_protocol_codec.dart';

void main() {
  test('stays dormant until a scope is added, then reconciles sets', () async {
    final binding = FakeBinding.scoped({});
    final transport = FakeTransport();
    final processor = FakeProcessor(binding);
    final worker = dormantWorkerFor(binding, transport, processor);

    worker.start();
    await transport.connected(1);
    await pumpEventQueue();
    expect(transport.sentFrames, isEmpty);
    expect(transport.pullBodies, isEmpty);

    await worker.replaceScopes([fakeScope]);
    await transport.pulled(1);
    expect(binding.cursors, {fakeScope: 0});
    expect(transport.restartCalls, 1);
    expect(decodeBody(transport.sentFrames.last), {
      'type': 'subscribe',
      'scopes': [fakeScope],
    });

    await worker.replaceScopes([fakeScope, bookScope]);
    await transport.pulled(3);
    expect(binding.cursors, {fakeScope: 0, bookScope: 0});
    expect(transport.restartCalls, 2);
    expect(decodeBody(transport.sentFrames.last), {
      'type': 'subscribe',
      'scopes': [bookScope, fakeScope],
    });

    await worker.replaceScopes([bookScope]);
    await transport.pulled(4);
    expect(transport.restartCalls, 3);
    expect(decodeBody(transport.sentFrames.last), {
      'type': 'subscribe',
      'scopes': [bookScope],
    });

    final sentBeforeIdle = transport.sentFrames.length;
    await worker.replaceScopes(const []);
    await pumpEventQueue();
    await worker.close();

    expect(transport.restartCalls, 4);
    expect(transport.sentFrames, hasLength(sentBeforeIdle));
  });

  test('readding a scope resumes its retained cursor', () async {
    final binding = FakeBinding.scoped({});
    final transport = FakeTransport();
    final worker = dormantWorkerFor(binding, transport, FakeProcessor(binding));
    await worker.replaceScopes([fakeScope]);
    worker.start();
    await transport.pulled(1);
    binding.cursor = 41;

    await worker.replaceScopes(const []);
    await worker.replaceScopes([fakeScope]);
    await transport.pulled(2);
    await worker.close();

    expect(decodeBody(transport.pullBodies.last), requestJson(41));
  });

  test('a pull result arriving after removal is discarded', () async {
    final pending = Completer<Uint8List>();
    final binding = FakeBinding.scoped({});
    final transport = FakeTransport(
      results: [pending.future],
      ignoreCancellation: true,
    );
    final processor = FakeProcessor(binding);
    final worker = dormantWorkerFor(binding, transport, processor);
    await worker.replaceScopes([fakeScope]);
    worker.start();
    await transport.pulled(1);

    await worker.replaceScopes(const []).timeout(const Duration(seconds: 1));
    pending.complete(pageBytes(0, 1));
    await pumpEventQueue();
    await worker.close();

    expect(processor.pages, isEmpty);
    expect(binding.cursor, 0);
  });

  test('removing one scope cancels only that scope pull', () async {
    final binding = FakeBinding.scoped({});
    final transport = FakeTransport(
      results: [Completer<Uint8List>().future, Completer<Uint8List>().future],
      ignoreCancellation: true,
    );
    final worker = dormantWorkerFor(binding, transport, FakeProcessor(binding));
    await worker.replaceScopes([fakeScope, bookScope]);
    worker.start();
    await transport.pulled(2);

    await worker.replaceScopes([bookScope]);
    expect(transport.cancelledScopes, [fakeScope]);

    await worker.close();
    expect(transport.cancelledScopes, [fakeScope, bookScope]);
  });

  test('remove and readd discards the prior generation result', () async {
    final stale = Completer<Uint8List>();
    final binding = FakeBinding.scoped({});
    final transport = FakeTransport(
      results: [stale.future, pageBytes(0, 1)],
      ignoreCancellation: true,
    );
    final processor = FakeProcessor(binding);
    final worker = dormantWorkerFor(binding, transport, processor);
    await worker.replaceScopes([fakeScope]);
    worker.start();
    await transport.pulled(1);

    await worker.replaceScopes(const []);
    await worker.replaceScopes([fakeScope]);
    await processor.applied(1);
    stale.complete(pageBytes(0, 2));
    await pumpEventQueue();
    await worker.close();

    expect(processor.pages.map((page) => page.throughSyncId), [1]);
    expect(binding.cursor, 1);
  });

  test('waits for an exact ack before catching up every scope', () async {
    final binding = FakeBinding.scoped({fakeScope: 100, bookScope: 200});
    final transport = FakeTransport(autoAck: false);
    final processor = FakeProcessor(binding);
    final worker = await workerFor(
      binding,
      transport,
      processor,
      scopes: [fakeScope, bookScope, fakeScope],
    );

    worker.start();
    await pumpUntil(() => transport.sentFrames.length == 1);

    expect(transport.pullBodies, isEmpty);
    expect(decodeBody(transport.sentFrames.single), {
      'type': 'subscribe',
      'scopes': [bookScope, fakeScope],
    });

    transport.deliver(subscribedBytes([fakeScope, bookScope]));
    await transport.pulled(2);
    await worker.close();

    expect(
      transport.pullBodies.map(decodeBody),
      unorderedEquals([
        requestJson(100, scope: fakeScope),
        requestJson(200, scope: bookScope),
      ]),
    );
  });

  test('a rejected scope does not stop an accepted scope', () async {
    final reported = <Object>[];
    final binding = FakeBinding.scoped({fakeScope: 0, bookScope: 0});
    final transport = FakeTransport(autoAck: false);
    final processor = FakeProcessor(binding);
    final worker = await workerFor(
      binding,
      transport,
      processor,
      scopes: [fakeScope, bookScope],
      failureObserver: reportingObserver(reported),
      sleep: neverSleep,
    );

    worker.start();
    await pumpUntil(() => transport.sentFrames.isNotEmpty);
    transport.deliver(
      subscribedBytes(
        [fakeScope],
        rejections: [(scope: bookScope, code: 'scope.forbidden')],
      ),
    );
    await transport.pulled(1);

    expect(decodeBody(transport.pullBodies.single), requestJson(0));
    expect(reported, isEmpty);

    await transport.reconnect();
    await pumpUntil(() => transport.sentFrames.length == 2);
    transport.deliver(
      subscribedBytes(
        [fakeScope],
        rejections: [(scope: bookScope, code: 'scope.forbidden')],
      ),
    );
    await transport.pulled(2);
    await pumpEventQueue();
    await worker.close();

    expect(reported, isEmpty);
  });

  test('a still-desired rejected scope retries on a fresh handshake', () async {
    final sleeps = <Completer<void>>[];
    final binding = FakeBinding.scoped({fakeScope: 0, bookScope: 0});
    final transport = FakeTransport(autoAck: false);
    final worker = await workerFor(
      binding,
      transport,
      FakeProcessor(binding),
      scopes: [fakeScope, bookScope],
      failureObserver: reportingObserver(<Object>[]),
      sleep: (_) {
        final wait = Completer<void>();
        sleeps.add(wait);
        return wait.future;
      },
    );

    worker.start();
    await pumpUntil(() => transport.sentFrames.isNotEmpty);
    transport.deliver(
      subscribedBytes(
        [fakeScope],
        rejections: [(scope: bookScope, code: 'scope.forbidden')],
      ),
    );
    await pumpUntil(() => sleeps.length == 1);

    sleeps.single.complete();
    await pumpUntil(() => transport.sentFrames.length == 2);
    transport.deliver(subscribedBytes([fakeScope, bookScope]));
    await transport.pulled(3);
    await worker.close();

    expect(transport.restartCalls, 1);
    expect(
      transport.pullBodies.map(decodeBody).any((request) {
        return request['scope'] == bookScope && request['afterSyncId'] == 0;
      }),
      isTrue,
    );
  });

  test('removing a rejected scope cancels its pending retry', () async {
    final sleeps = <Completer<void>>[];
    final binding = FakeBinding.scoped({fakeScope: 0, bookScope: 0});
    final transport = FakeTransport(autoAck: false);
    final worker = await workerFor(
      binding,
      transport,
      FakeProcessor(binding),
      scopes: [fakeScope, bookScope],
      failureObserver: reportingObserver(<Object>[]),
      sleep: (_) {
        final wait = Completer<void>();
        sleeps.add(wait);
        return wait.future;
      },
    );

    worker.start();
    await pumpUntil(() => transport.sentFrames.isNotEmpty);
    transport.deliver(
      subscribedBytes(
        [fakeScope],
        rejections: [(scope: bookScope, code: 'scope.forbidden')],
      ),
    );
    await pumpUntil(() => sleeps.length == 1);

    await worker.replaceScopes([fakeScope]);
    final restartsAfterRemoval = transport.restartCalls;
    sleeps.single.complete();
    await pumpEventQueue();
    await worker.close();

    expect(transport.restartCalls, restartsAfterRemoval);
  });

  test('an all-rejected acknowledgement starts no pulls', () async {
    final reported = <Object>[];
    final binding = FakeBinding.scoped({fakeScope: 0, bookScope: 0});
    final transport = FakeTransport(autoAck: false);
    final worker = await workerFor(
      binding,
      transport,
      FakeProcessor(binding),
      scopes: [fakeScope, bookScope],
      failureObserver: reportingObserver(reported),
      sleep: neverSleep,
    );

    worker.start();
    await pumpUntil(() => transport.sentFrames.isNotEmpty);
    transport.deliver(
      subscribedBytes(
        const [],
        rejections: [
          (scope: bookScope, code: 'scope.forbidden'),
          (scope: fakeScope, code: 'scope.forbidden'),
        ],
      ),
    );
    await pumpEventQueue();
    await worker.close();

    expect(transport.pullBodies, isEmpty);
    expect(reported, isEmpty);
  });

  test('an overlapping acknowledgement partition is terminal', () async {
    final reported = <Object>[];
    final binding = FakeBinding.scoped({fakeScope: 0, bookScope: 0});
    final transport = FakeTransport(autoAck: false);
    final worker = await workerFor(
      binding,
      transport,
      FakeProcessor(binding),
      scopes: [fakeScope, bookScope],
      failureObserver: reportingObserver(reported),
      sleep: neverSleep,
    );

    worker.start();
    await pumpUntil(() => transport.sentFrames.isNotEmpty);
    transport.deliver(
      subscribedBytes(
        [fakeScope],
        rejections: [
          (scope: fakeScope, code: 'scope.forbidden'),
          (scope: bookScope, code: 'scope.forbidden'),
        ],
      ),
    );
    await pumpUntil(() => reported.isNotEmpty);
    await worker.close();

    expect(reported.single, isA<LocalSyncTerminalException>());
    expect(transport.pullBodies, isEmpty);
  });

  test('a pull 403 disables only its scope', () async {
    final reported = <Object>[];
    final binding = FakeBinding.scoped({fakeScope: 0, bookScope: 0});
    final transport = FakeTransport(
      autoAck: false,
      results: [
        LocalSyncHttpResponse(
          statusCode: 403,
          body: encodeBytes({'code': 'scope.forbidden'}),
        ),
        pageBytes(0, 0, scope: fakeScope),
      ],
    );
    final processor = FakeProcessor(binding);
    final worker = await workerFor(
      binding,
      transport,
      processor,
      scopes: [fakeScope, bookScope],
      failureObserver: reportingObserver(reported),
      sleep: neverSleep,
    );

    worker.start();
    await pumpUntil(() => transport.sentFrames.isNotEmpty);
    transport.deliver(subscribedBytes([fakeScope, bookScope]));
    await transport.pulled(2);
    transport.deliver(pageBytes(0, 1, scope: fakeScope));
    await processor.applied(1);
    await worker.close();

    expect(binding.cursors[fakeScope], 1);
    expect(binding.cursors[bookScope], 0);
    expect(reported, isEmpty);
  });

  test('a mismatched ack is terminal protocol corruption', () async {
    final reported = <Object>[];
    final binding = FakeBinding.scoped({fakeScope: 100, bookScope: 200});
    final transport = FakeTransport(autoAck: false);
    final worker = await workerFor(
      binding,
      transport,
      FakeProcessor(binding),
      scopes: [fakeScope, bookScope],
      failureObserver: reportingObserver(reported),
    );

    worker.start();
    await pumpUntil(() => transport.sentFrames.isNotEmpty);
    transport.deliver(subscribedBytes([fakeScope]));
    await pumpUntil(() => reported.isNotEmpty);
    await worker.close();

    expect(reported.single, isA<LocalSyncTerminalException>());
    expect(transport.pullBodies, isEmpty);
    expect(transport.restartCalls, 0);
  });

  test('an ack with an extra scope is terminal protocol corruption', () async {
    final reported = <Object>[];
    final binding = FakeBinding(cursor: 100);
    final transport = FakeTransport(autoAck: false);
    final worker = await workerFor(
      binding,
      transport,
      FakeProcessor(binding),
      failureObserver: reportingObserver(reported),
    );

    worker.start();
    await pumpUntil(() => transport.sentFrames.isNotEmpty);
    transport.deliver(subscribedBytes([fakeScope, bookScope]));
    await pumpUntil(() => reported.isNotEmpty);
    await worker.close();

    expect(reported.single, isA<LocalSyncTerminalException>());
    expect(transport.pullBodies, isEmpty);
    expect(transport.restartCalls, 0);
  });

  test('a live page before ack forces reconnect without applying', () async {
    final reported = <Object>[];
    final binding = FakeBinding(cursor: 100);
    final transport = FakeTransport(autoAck: false);
    final processor = FakeProcessor(binding);
    final worker = await workerFor(
      binding,
      transport,
      processor,
      failureObserver: reportingObserver(reported),
    );

    worker.start();
    await pumpUntil(() => transport.sentFrames.isNotEmpty);
    transport.deliver(pageBytes(100, 101));
    await pumpUntil(() => transport.restartCalls == 1);
    await worker.close();

    expect(processor.pages, isEmpty);
    expect(transport.pullBodies, isEmpty);
    expect(reported.single, isA<DownlinkPageException>());
  });

  test('an inactive-scope live page forces reconnect', () async {
    final reported = <Object>[];
    final binding = FakeBinding(cursor: 100);
    final transport = FakeTransport(autoAck: false);
    final processor = FakeProcessor(binding);
    final worker = await workerFor(
      binding,
      transport,
      processor,
      failureObserver: reportingObserver(reported),
    );

    worker.start();
    await pumpUntil(() => transport.sentFrames.isNotEmpty);
    transport.deliver(subscribedBytes([fakeScope]));
    await transport.pulled(1);
    transport.deliver(pageBytes(0, 1, scope: bookScope));
    await pumpUntil(() => transport.restartCalls == 1);
    await worker.close();

    expect(processor.pages, isEmpty);
    expect(reported.single, isA<DownlinkPageException>());
  });

  test('interleaved live pages advance only their own scope', () async {
    final binding = FakeBinding.scoped({fakeScope: 100, bookScope: 200});
    final transport = FakeTransport(autoAck: false);
    final processor = FakeProcessor(binding);
    final worker = await workerFor(
      binding,
      transport,
      processor,
      scopes: [fakeScope, bookScope],
    );

    worker.start();
    await pumpUntil(() => transport.sentFrames.isNotEmpty);
    transport.deliver(subscribedBytes([bookScope, fakeScope]));
    await transport.pulled(2);
    transport.deliver(pageBytes(200, 201, scope: bookScope));
    transport.deliver(pageBytes(100, 101, scope: fakeScope));
    await processor.applied(2);
    await worker.close();

    expect(binding.cursors, {fakeScope: 101, bookScope: 201});
  });

  test('a gap catches up only the affected scope', () async {
    final binding = FakeBinding.scoped({fakeScope: 100, bookScope: 200});
    final transport = FakeTransport(autoAck: false);
    final processor = FakeProcessor(binding);
    final worker = await workerFor(
      binding,
      transport,
      processor,
      scopes: [fakeScope, bookScope],
    );

    worker.start();
    await pumpUntil(() => transport.sentFrames.isNotEmpty);
    transport.deliver(subscribedBytes([fakeScope, bookScope]));
    await transport.pulled(2);
    transport.results.addAll([
      pageBytes(100, 110, scope: fakeScope),
      pageBytes(110, 110, scope: fakeScope),
    ]);
    transport.deliver(pageBytes(110, 120, scope: fakeScope));
    transport.deliver(pageBytes(200, 201, scope: bookScope));
    await processor.applied(3);
    await transport.pulled(4);
    await worker.close();

    expect(binding.cursors, {fakeScope: 120, bookScope: 201});
    expect(transport.pullBodies.skip(2).map(decodeBody), [
      requestJson(100),
      requestJson(110),
    ]);
  });

  test('reconnect handshakes again before rereading durable cursors', () async {
    final binding = FakeBinding.scoped({fakeScope: 100, bookScope: 200});
    final transport = FakeTransport(autoAck: false);
    final processor = FakeProcessor(binding);
    final worker = await workerFor(
      binding,
      transport,
      processor,
      scopes: [fakeScope, bookScope],
    );

    worker.start();
    await pumpUntil(() => transport.sentFrames.length == 1);
    transport.deliver(subscribedBytes([fakeScope, bookScope]));
    await transport.pulled(2);
    binding.cursors[fakeScope] = 101;
    binding.cursors[bookScope] = 202;

    await transport.reconnect();
    await pumpUntil(() => transport.sentFrames.length == 2);
    await pumpEventQueue();
    expect(transport.pullBodies, hasLength(2));
    transport.deliver(subscribedBytes([bookScope, fakeScope]));
    await transport.pulled(4);
    await worker.close();

    expect(
      transport.pullBodies.skip(2).map(decodeBody),
      unorderedEquals([
        requestJson(101, scope: fakeScope),
        requestJson(202, scope: bookScope),
      ]),
    );
  });

  test('opening the stream catches up, and so does every reopen', () async {
    final binding = FakeBinding(cursor: 100);
    final transport = FakeTransport();
    final processor = FakeProcessor(binding);
    final worker = await workerFor(binding, transport, processor);

    worker.start();
    await transport.pulled(1);
    await transport.reconnect();
    await transport.pulled(2);
    await worker.close();

    expect(transport.pullBodies.map(decodeBody), [
      requestJson(100),
      requestJson(100),
    ]);
    expect(transport.connects, 2);
    expect(processor.pages, isEmpty);
  });

  test('a reconnect during catch-up schedules a fresh catch-up', () async {
    final binding = FakeBinding(cursor: 100);
    final first = Completer<Uint8List>();
    final transport = FakeTransport(results: [first.future]);
    final processor = FakeProcessor(binding);
    final worker = await workerFor(binding, transport, processor);

    worker.start();
    await transport.pulled(1);
    await transport.reconnect();
    first.complete(pageBytes(100, 100));
    await transport.pulled(2).timeout(const Duration(seconds: 1));
    await worker.close();

    expect(transport.pullBodies.map(decodeBody), [
      requestJson(100),
      requestJson(100),
    ]);
  });

  test('a contiguous live page applies without a further pull', () async {
    final binding = FakeBinding(cursor: 100);
    final transport = FakeTransport();
    final processor = FakeProcessor(binding);
    final worker = await workerFor(binding, transport, processor);

    worker.start();
    await transport.pulled(1);
    transport.deliver(pageBytes(100, 101));
    await processor.applied(1);
    await worker.close();

    expect(binding.cursor, 101);
    expect(transport.pullBodies, hasLength(1));
  });

  test('catch-up starts before a simultaneously queued page', () async {
    final binding = FakeBinding(cursor: 100);
    final transport = FakeTransport();
    final processor = FakeProcessor(binding);
    final worker = await workerFor(binding, transport, processor);

    worker.start();
    await transport.connected(1);
    transport.deliver(pageBytes(100, 101));
    await processor.applied(1);
    await worker.close();

    expect(decodeBody(transport.pullBodies.single), requestJson(100));
    expect(binding.cursor, 101);
  });

  test('an advancing empty live page advances the cursor', () async {
    final binding = FakeBinding(cursor: 100);
    final transport = FakeTransport();
    final processor = FakeProcessor(binding);
    final worker = await workerFor(binding, transport, processor);

    worker.start();
    await transport.pulled(1);
    transport.deliver(pageBytes(100, 120));
    await processor.applied(1);
    await worker.close();

    expect(processor.pages.single.changes, isEmpty);
    expect(binding.cursor, 120);
  });

  test('drops a page already covered by the durable cursor', () async {
    final binding = FakeBinding(cursor: 120);
    final transport = FakeTransport();
    final processor = FakeProcessor(binding);
    final worker = await workerFor(binding, transport, processor);

    worker.start();
    await transport.pulled(1);
    transport.deliver(pageBytes(100, 120));
    await pumpEventQueue();
    await worker.close();

    expect(processor.pages, isEmpty);
    expect(transport.pullBodies, hasLength(1));
  });

  test(
    'orders pages received out of order before the loop reads cursor',
    () async {
      final binding = FakeBinding(cursor: 100);
      final transport = FakeTransport();
      final processor = FakeProcessor(binding);
      final worker = await workerFor(binding, transport, processor);

      worker.start();
      await transport.pulled(1);
      transport.deliver(pageBytes(110, 120));
      transport.deliver(pageBytes(100, 110));
      await processor.applied(2);
      await worker.close();

      expect(processor.pages.map((page) => page.throughSyncId), [110, 120]);
    },
  );

  test('queues a live page received during catch-up', () async {
    final binding = FakeBinding(cursor: 100);
    final catchUp = Completer<Uint8List>();
    final transport = FakeTransport(results: [catchUp.future]);
    final processor = FakeProcessor(binding);
    final worker = await workerFor(binding, transport, processor);

    worker.start();
    await transport.pulled(1);
    transport.deliver(pageBytes(100, 101));
    catchUp.complete(pageBytes(100, 100));
    await processor.applied(1);
    await worker.close();

    expect(processor.pages.single.throughSyncId, 101);
    expect(transport.pullBodies, hasLength(1));
  });

  test('repairs a gap with a pull before applying the queued page', () async {
    final binding = FakeBinding(cursor: 100);
    final transport = FakeTransport(
      results: [
        pageBytes(100, 100),
        pageBytes(100, 110),
        pageBytes(110, 120),
        pageBytes(120, 120),
      ],
    );
    final processor = FakeProcessor(binding);
    final worker = await workerFor(binding, transport, processor);

    worker.start();
    await transport.pulled(1);
    transport.deliver(pageBytes(110, 120));
    await processor.applied(2);
    await transport.pulled(4);
    await worker.close();

    expect(processor.pages.map((page) => page.throughSyncId), [110, 120]);
    expect(transport.pullBodies.map(decodeBody), [
      requestJson(100),
      requestJson(100),
      requestJson(110),
      requestJson(120),
    ]);
  });

  test('discards an overlap and repairs from the durable cursor', () async {
    final binding = FakeBinding(cursor: 110);
    final transport = FakeTransport();
    final processor = FakeProcessor(binding);
    final worker = await workerFor(binding, transport, processor);

    worker.start();
    await transport.pulled(1);
    transport.deliver(pageBytes(100, 120));
    await transport.pulled(2);
    await worker.close();

    expect(processor.pages, isEmpty);
    expect(transport.pullBodies.map(decodeBody), [
      requestJson(110),
      requestJson(110),
    ]);
  });

  test('queue overflow clears live pages and repairs with a pull', () async {
    final binding = FakeBinding(cursor: 100);
    final transport = FakeTransport();
    final processor = FakeProcessor(binding);
    final worker = await workerFor(binding, transport, processor);

    worker.start();
    await transport.pulled(1);
    for (var index = 0; index < 65; index += 1) {
      transport.deliver(pageBytes(200 + index, 201 + index));
    }
    await transport.pulled(2);
    await worker.close();

    expect(processor.pages, isEmpty);
    expect(decodeBody(transport.pullBodies.last), requestJson(100));
  });

  test('reports an invalid live page and repairs with a pull', () async {
    final reported = <Object>[];
    final observer = reportingObserver(reported);
    final binding = FakeBinding(cursor: 100);
    final transport = FakeTransport();
    final processor = FakeProcessor(binding);
    final worker = await workerFor(
      binding,
      transport,
      processor,
      failureObserver: observer,
    );

    worker.start();
    await transport.pulled(1);
    transport.deliver(Uint8List.fromList(utf8.encode('{"syncId":101}')));
    await transport.pulled(2);
    await pumpUntil(() => reported.isNotEmpty);
    await worker.close();

    expect(reported.single, isA<DownlinkPageException>());
    expect(binding.cursor, 100);
  });

  test('reports committed change failures and applies later pages', () async {
    final failures = <LocalSyncClientFailure>[];
    final binding = FakeBinding(cursor: 100);
    final transport = FakeTransport();
    final failure = DownlinkChangeException(
      syncId: 101,
      model: 'Test',
      operation: 'upsert',
      cause: StateError('bad change'),
      stackTrace: StackTrace.current,
    );
    final processor = FakeProcessor(binding)..nextFailures.add([failure]);
    final worker = await workerFor(
      binding,
      transport,
      processor,
      failureObserver: failures.add,
    );

    worker.start();
    await transport.pulled(1);
    transport.deliver(pageBytes(100, 101));
    transport.deliver(pageBytes(101, 102));
    await processor.applied(2);
    await pumpUntil(() => failures.isNotEmpty);
    await worker.close();

    expect(failures.single.error, same(failure));
    expect(failures.single.stackTrace, same(failure.stackTrace));
    expect(failures.single.boundary, LocalSyncClientFailureBoundary.downlink);
    expect(failures.single.fate, LocalSyncClientFailureFate.continuing);
    expect(binding.cursor, 102);
  });

  test('retries a retryable pull, paced by the retry policy', () async {
    final binding = FakeBinding(cursor: 100);
    final transport = FakeTransport(
      results: [
        const LocalSyncRetryableTransportFailure('unavailable', status: 503),
        pageBytes(100, 100),
      ],
    );
    final processor = FakeProcessor(binding);
    final sleeps = <Duration>[];
    final worker = await workerFor(
      binding,
      transport,
      processor,
      sleep: (duration) async => sleeps.add(duration),
    );

    worker.start();
    await transport.pulled(2);
    await worker.close();

    expect(sleeps.first, const Duration(milliseconds: 500));
  });

  test('a cancelled pull the worker did not ask for is retried', () async {
    final binding = FakeBinding(cursor: 100);
    final transport = FakeTransport(
      results: [
        const LocalSyncCancelledTransportFailure('cancelled', status: 499),
        pageBytes(100, 101),
      ],
    );
    final processor = FakeProcessor(binding);
    final worker = await workerFor(binding, transport, processor);

    worker.start();
    await processor.applied(1);
    await worker.close();

    expect(binding.cursor, 101);
    expect(transport.pullBodies.take(2).map(decodeBody), [
      requestJson(100),
      requestJson(100),
    ]);
  });

  test('reports an unclassified pull error and retries it', () async {
    final failures = <LocalSyncClientFailure>[];
    final error = StateError('token fetch failed');
    final binding = FakeBinding(cursor: 100);
    // A credential fetch throws outside the transport's own classification.
    final transport = FakeTransport(
      results: [error, error, pageBytes(100, 101)],
    );
    final processor = FakeProcessor(binding);
    final worker = await workerFor(
      binding,
      transport,
      processor,
      failureObserver: failures.add,
    );

    worker.start();
    await processor.applied(1);
    await transport.pulled(4);
    await pumpEventQueue();
    final secondError = StateError('second token fetch failed');
    transport.results.add(secondError);
    await transport.reconnect();
    await pumpUntil(() => failures.length == 2);
    await worker.close();

    expect(failures.first.error, same(error));
    expect(failures.last.error, same(secondError));
    expect(
      failures.map((failure) => failure.boundary),
      everyElement(LocalSyncClientFailureBoundary.downlink),
    );
    expect(
      failures.map((failure) => failure.fate),
      everyElement(LocalSyncClientFailureFate.retrying),
    );
    expect(binding.cursor, 101);
    expect(transport.pullBodies.length, greaterThanOrEqualTo(2));
  });

  test('reports a terminal pull once and stops only this worker', () async {
    final failures = <LocalSyncClientFailure>[];
    final binding = FakeBinding(cursor: 100);
    final transport = FakeTransport(
      results: [
        const LocalSyncTerminalTransportFailure(
          'invalid argument',
          status: 400,
        ),
      ],
    );
    final processor = FakeProcessor(binding);
    final worker = await workerFor(
      binding,
      transport,
      processor,
      failureObserver: failures.add,
    );

    worker.start();
    await pumpUntil(() => failures.isNotEmpty);
    transport.deliver(pageBytes(100, 101));
    await pumpEventQueue();
    await worker.close();

    expect(failures, hasLength(1));
    expect(failures.single.error, isA<LocalSyncTerminalException>());
    expect(failures.single.boundary, LocalSyncClientFailureBoundary.downlink);
    expect(failures.single.fate, LocalSyncClientFailureFate.terminal);
    expect(transport.pullBodies, hasLength(1));
    expect(binding.cursor, 100);
  });

  test('a throwing observer cannot change retry and apply fate', () async {
    final binding = FakeBinding(cursor: 100);
    final transport = FakeTransport(
      results: [StateError('unknown'), pageBytes(100, 101)],
    );
    final processor = FakeProcessor(binding);
    final worker = await workerFor(
      binding,
      transport,
      processor,
      failureObserver: (_) => throw StateError('observer'),
    );

    worker.start();
    await processor.applied(1);
    await worker.close();

    expect(binding.cursor, 101);
  });

  test('a reconnect catches up again', () async {
    final binding = FakeBinding(cursor: 100);
    final transport = FakeTransport();
    final processor = FakeProcessor(binding);
    final worker = await workerFor(binding, transport, processor);

    worker.start();
    await transport.pulled(1);
    await transport.reconnect();
    await transport.pulled(2);
    await worker.close();

    expect(transport.connects, 2);
  });

  test('a healthy reconnect does not inherit a stale backoff', () async {
    final binding = FakeBinding(cursor: 100);
    final transport = FakeTransport(
      results: [
        pageBytes(100, 100),
        const LocalSyncRetryableTransportFailure('unavailable', status: 503),
        pageBytes(100, 110),
      ],
    );
    final processor = FakeProcessor(binding);
    final sleeps = <Duration>[];
    final worker = await workerFor(
      binding,
      transport,
      processor,
      sleep: (duration) async => sleeps.add(duration),
    );

    worker.start();
    await transport.pulled(1);
    transport.deliver(pageBytes(110, 120));
    await processor.applied(2);
    await transport.reconnect();
    await transport.connected(2);
    await worker.close();

    expect(binding.cursor, 120);
    expect(sleeps, isNotEmpty);
    expect(sleeps, everyElement(const Duration(milliseconds: 500)));
  });

  test('close cancels an outstanding retry and queued pages', () async {
    final binding = FakeBinding(cursor: 100);
    final transport = FakeTransport(
      results: [
        const LocalSyncRetryableTransportFailure('unavailable', status: 503),
      ],
    );
    final processor = FakeProcessor(binding);
    final sleeping = Completer<void>();
    final worker = await workerFor(
      binding,
      transport,
      processor,
      sleep: (_) => sleeping.future,
    );

    worker.start();
    await transport.pulled(1);
    transport.deliver(pageBytes(100, 101));

    await worker.close().timeout(const Duration(seconds: 1));

    expect(processor.pages, isEmpty);
    expect(binding.cursor, 100);
  });

  test('close cancels outstanding pulls for every scope', () async {
    final binding = FakeBinding.scoped({fakeScope: 100, bookScope: 200});
    final transport = FakeTransport(
      results: [Completer<Uint8List>().future, Completer<Uint8List>().future],
    );
    final processor = FakeProcessor(binding);
    final worker = await workerFor(
      binding,
      transport,
      processor,
      scopes: [fakeScope, bookScope],
    );

    worker.start();
    await transport.pulled(2);
    await worker.close().timeout(const Duration(seconds: 1));

    expect(transport.cancelCalls, 2);
    expect(processor.pages, isEmpty);
  });

  test('close stops waiting for an outstanding catch-up pull', () async {
    final binding = FakeBinding(cursor: 100);
    final pending = Completer<Uint8List>();
    final transport = FakeTransport(results: [pending.future]);
    final processor = FakeProcessor(binding);
    final worker = await workerFor(binding, transport, processor);

    worker.start();
    await transport.pulled(1);

    await worker.close().timeout(const Duration(seconds: 1));

    expect(transport.cancelCalls, greaterThan(0));
    expect(binding.cursor, 100);
  });

  test('close stops reading the live channel', () async {
    final binding = FakeBinding(cursor: 100);
    final transport = FakeTransport();
    final processor = FakeProcessor(binding);
    final worker = await workerFor(binding, transport, processor);

    worker.start();
    await transport.connected(1);

    await worker.close().timeout(const Duration(seconds: 1));
    transport.deliver(pageBytes(100, 101));
    await pumpEventQueue();

    expect(processor.pages, isEmpty);
    expect(binding.cursor, 100);
  });
}

const clientId = '5d6c1f20-9105-4f7e-89d7-163fa5dcbb84';
const bookScope = 'Book:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

Map<String, Object?> requestJson(int afterSyncId, {String? scope}) {
  final requested = scope ?? fakeScope;
  return {'clientId': clientId, 'scope': requested, 'afterSyncId': afterSyncId};
}

Future<DownlinkWorker> workerFor(
  FakeBinding binding,
  FakeTransport transport,
  FakeProcessor processor, {
  Iterable<String>? scopes,
  LocalSyncClientFailureObserver? failureObserver,
  DownlinkSleep? sleep,
}) async {
  final worker = DownlinkWorker(
    state: binding,
    processor: processor,
    transport: transport,
    codec: const FakeProtocolCodec(),
    retryPolicyFactory: () => RetryPolicy(randomDouble: () => 0.5),
    failureObserver: failureObserver,
    sleep: sleep ?? (_) async {},
  );
  await worker.replaceScopes(scopes ?? [fakeScope]);
  return worker;
}

Future<void> neverSleep(Duration _) => Completer<void>().future;

DownlinkWorker dormantWorkerFor(
  FakeBinding binding,
  FakeTransport transport,
  FakeProcessor processor,
) => DownlinkWorker(
  state: binding,
  processor: processor,
  transport: transport,
  codec: const FakeProtocolCodec(),
  retryPolicyFactory: () => RetryPolicy(randomDouble: () => 0.5),
  sleep: (_) async {},
);

LocalSyncClientFailureObserver reportingObserver(List<Object> reported) =>
    (failure) => reported.add(failure.error);

Map<String, Object?> pageJson(
  int fromSyncId,
  int throughSyncId, {
  String? scope,
}) {
  final addressed = scope ?? fakeScope;
  return {
    'scope': addressed,
    'fromSyncId': fromSyncId,
    'changes': <Object?>[],
    'throughSyncId': throughSyncId,
  };
}

Uint8List pageBytes(int fromSyncId, int throughSyncId, {String? scope}) =>
    encodeBytes(pageJson(fromSyncId, throughSyncId, scope: scope));

Uint8List subscribedBytes(
  Iterable<String> scopes, {
  Iterable<({String scope, String code})> rejections = const [],
}) => encodeBytes({
  'type': 'subscribed',
  'scopes': scopes.toList(),
  'rejections': [
    for (final rejection in rejections)
      {'scope': rejection.scope, 'code': rejection.code},
  ],
});

Map<String, Object?> decodeBody(Uint8List body) =>
    (jsonDecode(utf8.decode(body)) as Map).cast<String, Object?>();

Future<void> pumpUntil(bool Function() condition) async {
  while (!condition()) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> pumpEventQueue() async {
  for (var index = 0; index < 10; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// The wire port, scripted. A pull with nothing scripted answers "nothing new
/// since your cursor", which is what a healthy server says most of the time;
/// the live channel is a controller the test drives event by event.
///
/// Reconnect and live-channel failure belong to the transport now, so what the
/// worker can observe of them is exactly one thing: the channel is open again.
final class FakeTransport implements LocalSyncTransport {
  FakeTransport({
    List<Object>? results,
    this.autoAck = true,
    this.ignoreCancellation = false,
  }) : results = [...?results];

  final List<Object> results;
  final bool autoAck;
  final bool ignoreCancellation;
  final pullBodies = <Uint8List>[];
  final cancelledScopes = <String>[];
  final sentFrames = <Uint8List>[];
  late final StreamController<DownlinkTransportEvent> _events =
      StreamController<DownlinkTransportEvent>.broadcast(onListen: connect);
  int connects = 0;
  int cancelCalls = 0;
  int restartCalls = 0;

  @override
  Stream<DownlinkTransportEvent> get downlinkEvents => _events.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> sendDownlinkFrame(Uint8List frame) async {
    sentFrames.add(frame);
    if (!autoAck) return;
    final envelope = decodeBody(frame);
    final scopes = (envelope['scopes']! as List<Object?>).cast<String>();
    deliver(subscribedBytes(scopes));
  }

  @override
  Future<void> restartDownlinkConnection() async {
    restartCalls += 1;
    connect();
  }

  @override
  Future<LocalSyncHttpResponse> sendUplink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  }) => throw StateError('Downlink worker must not send Uplink');

  @override
  Future<LocalSyncHttpResponse> fetchDownlink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  }) {
    pullBodies.add(body);
    final call = Completer<LocalSyncHttpResponse>();
    bindLocalSyncCancellation(cancellation, () async {
      _cancel();
      final request = decodeBody(body);
      cancelledScopes.add(request['scope']! as String);
      if (ignoreCancellation) return;
      if (!call.isCompleted) {
        call.completeError(
          const LocalSyncCancelledTransportFailure('cancelled', status: 499),
        );
      }
    });
    _settle(call, body);
    return call.future;
  }

  void _settle(Completer<LocalSyncHttpResponse> call, Uint8List body) {
    if (results.isEmpty) {
      final request = decodeBody(body);
      final afterSyncId = request['afterSyncId']! as int;
      final scope = request['scope']! as String;
      call.complete(_ok(pageBytes(afterSyncId, afterSyncId, scope: scope)));
      return;
    }
    final result = results.removeAt(0);
    if (result is Future<Uint8List>) {
      result.then((bytes) {
        if (!call.isCompleted) call.complete(_ok(bytes));
      });
      return;
    }
    if (result is Uint8List) {
      call.complete(_ok(result));
      return;
    }
    if (result is LocalSyncHttpResponse) {
      call.complete(result);
      return;
    }
    call.completeError(result);
  }

  static LocalSyncHttpResponse _ok(Uint8List body) =>
      LocalSyncHttpResponse(statusCode: 200, body: body);

  @override
  Future<void> close() async {
    await _events.close();
  }

  /// The channel is open — the first time and after every reconnect.
  void connect() {
    connects += 1;
    _events.add(const DownlinkConnected());
  }

  Future<void> reconnect() async {
    connect();
    await pumpEventQueue();
  }

  void deliver(Uint8List page) => _events.add(DownlinkPageReceived(page));

  Future<void> pulled(int count) => pumpUntil(() => pullBodies.length >= count);

  Future<void> connected(int count) => pumpUntil(() => connects >= count);

  void _cancel() => cancelCalls += 1;
}

final class FakeBinding implements DownlinkStateReader {
  FakeBinding({required int cursor}) : cursors = {fakeScope: cursor};

  FakeBinding.scoped(Map<String, int> cursors) : cursors = {...cursors};

  final Map<String, int> cursors;
  int get cursor => cursors[fakeScope]!;
  set cursor(int value) => cursors[fakeScope] = value;

  @override
  Future<String> readClientId() async => clientId;
  @override
  Future<int> readLastAppliedSyncId(String scope) async =>
      cursors.putIfAbsent(scope, () => 0);
}

final class FakeProcessor implements DownlinkPageHandler {
  FakeProcessor(this.binding);

  final FakeBinding binding;
  final pages = <DownlinkPage>[];
  final nextFailures = <List<DownlinkChangeException>>[];

  @override
  Future<DownlinkApplyResult> apply(
    DownlinkPage page, {
    required int afterSyncId,
  }) async {
    if (binding.cursors[page.scope] != afterSyncId ||
        page.fromSyncId != afterSyncId) {
      throw StateError('stale cursor');
    }
    pages.add(page);
    binding.cursors[page.scope] = page.throughSyncId;
    return DownlinkApplyResult(
      nextFailures.isEmpty ? const [] : nextFailures.removeAt(0),
    );
  }

  Future<void> applied(int count) => pumpUntil(() => pages.length >= count);
}
