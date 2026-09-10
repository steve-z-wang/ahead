import 'dart:async';
import 'dart:typed_data';

import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

/// One inner transport per credential intent, scripted by status.
final class _Script {
  final List<String> calls = <String>[];
  final List<String> tokens = <String>[];
  final List<bool> refreshFlags = <bool>[];
  final List<int> statuses = <int>[];
  int closeCalls = 0;
  int startCalls = 0;
}

final class _ScriptedTransport implements LocalSyncTransport {
  _ScriptedTransport(this._script, this._getAccessToken);

  final _Script _script;
  final Future<String> Function() _getAccessToken;

  @override
  Stream<DownlinkTransportEvent> get downlinkEvents =>
      const Stream<DownlinkTransportEvent>.empty();

  @override
  Future<void> start() async {
    _script.startCalls += 1;
  }

  @override
  Future<LocalSyncHttpResponse> sendUplink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  }) => _answer('sendUplink', body);

  @override
  Future<LocalSyncHttpResponse> fetchDownlink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  }) => _answer('fetchDownlink', body);

  @override
  Future<void> sendDownlinkFrame(Uint8List frame) async {
    _script.calls.add('sendDownlinkFrame');
  }

  @override
  Future<void> restartDownlinkConnection() async {
    _script.calls.add('restartDownlinkConnection');
  }

  @override
  Future<void> close() async {
    _script.closeCalls += 1;
  }

  Future<LocalSyncHttpResponse> _answer(String call, Uint8List body) async {
    _script.calls.add(call);
    _script.tokens.add(await _getAccessToken());
    final status = _script.statuses.isEmpty
        ? 200
        : _script.statuses.removeAt(0);
    return LocalSyncHttpResponse(statusCode: status, body: body);
  }
}

({AuthRefreshingTransport wrapper, _Script script}) _build() {
  final script = _Script();
  var fresh = 0;
  var cached = 0;
  final wrapper = AuthRefreshingTransport(
    provider: ({bool forceRefresh = false}) async {
      script.refreshFlags.add(forceRefresh);
      return forceRefresh ? 'fresh-${++fresh}' : 'cached-${++cached}';
    },
    inner: (getAccessToken) => _ScriptedTransport(script, getAccessToken),
  );
  return (wrapper: wrapper, script: script);
}

Uint8List _bytes(int value) => Uint8List.fromList([value]);

void main() {
  test('live frame operations stay on the cached transport', () async {
    final built = _build();

    await built.wrapper.sendDownlinkFrame(_bytes(1));
    await built.wrapper.restartDownlinkConnection();

    expect(built.script.calls, [
      'sendDownlinkFrame',
      'restartDownlinkConnection',
    ]);
    expect(built.script.refreshFlags, isEmpty);
  });

  test('a successful call asks for the cached credential once', () async {
    final built = _build();

    final response = await built.wrapper.sendUplink(_bytes(7));

    expect(response.statusCode, 200);
    expect(response.body, _bytes(7));
    expect(built.script.refreshFlags, [false]);
    expect(built.script.tokens, ['cached-1']);
  });

  test('an unauthorized call refreshes once and retries', () async {
    final built = _build();
    built.script.statuses.add(401);

    final response = await built.wrapper.sendUplink(_bytes(2));

    expect(response.statusCode, 200);
    expect(built.script.refreshFlags, [false, true]);
    expect(built.script.tokens.last, startsWith('fresh-'));
    expect(built.script.calls, ['sendUplink', 'sendUplink']);
  });

  test('a second unauthorized answer reaches the caller', () async {
    final built = _build();
    built.script.statuses
      ..add(401)
      ..add(401);

    final response = await built.wrapper.fetchDownlink(_bytes(2));

    expect(response.statusCode, 401);
    expect(built.script.refreshFlags, [false, true]);
    expect(built.script.calls, ['fetchDownlink', 'fetchDownlink']);
  });

  test('a refusal that is not unauthorized is never retried', () async {
    final built = _build();
    built.script.statuses.add(403);

    final response = await built.wrapper.sendUplink(_bytes(2));

    expect(response.statusCode, 403);
    expect(built.script.refreshFlags, [false]);
  });

  test('a retryable status passes through untouched', () async {
    final built = _build();
    built.script.statuses.add(503);

    final response = await built.wrapper.sendUplink(_bytes(2));

    expect(response.statusCode, 503);
    expect(built.script.refreshFlags, [false]);
  });

  test('the live channel and the lifecycle belong to one instance', () async {
    final built = _build();
    built.script.statuses.add(401);
    await built.wrapper.sendUplink(_bytes(1));

    await built.wrapper.start();
    await built.wrapper.close();

    expect(built.script.startCalls, 1);
    expect(built.script.closeCalls, 1);
  });
}
