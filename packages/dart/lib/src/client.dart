import 'connection.dart';
import 'live.dart';
import 'port.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:io';
import 'package:ffi/ffi.dart';

typedef _CallNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _Call = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _Free = void Function(Pointer<Utf8>);

void _nativeWorker(List<Object?> args) {
  final ready = args[0] as SendPort;
  try {
    final libraryPath = args[1] as String?;
    final library = libraryPath != null
        ? DynamicLibrary.open(libraryPath)
        : Platform.isIOS
        ? DynamicLibrary.process()
        : throw StateError('libraryPath is required outside iOS');
    final call = library.lookupFunction<_CallNative, _Call>('ahead_call');
    final free = library.lookupFunction<_FreeNative, _Free>('ahead_free');
    final port = ReceivePort();
    ready.send(port.sendPort);
    port.listen((dynamic raw) {
      if (raw == null) {
        port.close();
        return;
      }
      final message = raw as List;
      final reply = message[1] as SendPort;
      final input = (message[0] as String).toNativeUtf8();
      try {
        final output = call(input);
        try {
          reply.send(output.toDartString());
        } finally {
          free(output);
        }
      } catch (error) {
        reply.send(jsonEncode({'ok': false, 'error': error.toString()}));
      } finally {
        calloc.free(input);
      }
    });
  } catch (error) {
    ready.send(error.toString());
  }
}

/// Typed generated model APIs delegate to this generic native client.
class Client implements ReadPort {
  final SendPort _worker;
  final Isolate _isolate;
  final int _handle;
  final String clientId;
  Future<void> _tail = Future<void>.value();
  int _liveGeneration = 0;
  final _channels = StreamController<void>.broadcast(sync: true);
  Future<void>? _syncing;
  Future<void>? _tasks;
  bool _closed = false;
  RuntimeConnection? _connection;
  bool _connecting = false;
  Completer<void>? _started;
  Future<void>? _closing;
  final _work = StreamController<void>.broadcast();
  final _changes = StreamController<void>.broadcast();
  Client._(this._worker, this._isolate, this._handle, this.clientId);
  static Future<Client> open({
    required String path,
    required Map<String, dynamic> schema,
    String? libraryPath,
    Map<String, dynamic>? migration,
  }) async {
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(_nativeWorker, [
      ready.sendPort,
      libraryPath,
    ]);
    final response = await ready.first;
    ready.close();
    if (response is! SendPort) {
      isolate.kill();
      throw StateError('$response');
    }
    try {
      final opened = await _request(response, {
        'op': 'open',
        'path': path,
        'schema': schema,
        if (migration != null) 'migration': migration,
      });
      final value = opened['value'] as Map;
      return Client._(
        response,
        isolate,
        value['handle'] as int,
        value['clientId'] as String,
      );
    } catch (_) {
      response.send(null);
      isolate.kill();
      rethrow;
    }
  }

  static Future<Map<String, dynamic>> _request(
    SendPort worker,
    Map<String, dynamic> request,
  ) async {
    final reply = ReceivePort();
    worker.send([jsonEncode(request), reply.sendPort]);
    try {
      final response =
          jsonDecode(await reply.first as String) as Map<String, dynamic>;
      if (response['ok'] != true) throw StateError(response['error'] as String);
      return response['result'] as Map<String, dynamic>;
    } finally {
      reply.close();
    }
  }

  Future<T> _exclusive<T>(Future<T> Function() body) {
    final work = _tail.then((_) => body());
    _tail = work.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return work;
  }

  Future<dynamic> _send(Map<String, dynamic> request) async {
    if (_closed) throw StateError('client_closed');
    final response = await _request(_worker, {'handle': _handle, ...request});
    if (response['changed'] == true) _changes.add(null);
    return response['value'];
  }

  Future<T> transaction<T>(Future<T> Function(Transaction tx) body) =>
      _exclusive(() async {
        await _send({'op': 'begin'});
        final tx = Transaction._(this);
        try {
          final result = await body(tx);
          await tx._finish();
          await _send({'op': 'commit'});
          _work.add(null);
          return result;
        } catch (error, stack) {
          try {
            await tx._finish();
          } catch (_) {}
          try {
            await _send({'op': 'rollback'});
          } catch (_) {}
          Error.throwWithStackTrace(error, stack);
        }
      });
  Future<Map<String, dynamic>?> read(
    String model,
    Map<String, dynamic> identity,
  ) => _exclusive(
    () async =>
        (await _send({
              'op': 'read',
              'key': {'model': model, 'identity': identity},
            }))
            as Map<String, dynamic>?,
  );
  Future<List<Map<String, dynamic>>> query(
    String model, {
    Map<String, dynamic> where = const {},
  }) => _exclusive(
    () async =>
        (await _send({'op': 'query', 'model': model, 'filter': where}) as List)
            .cast<Map<String, dynamic>>(),
  );
  Future<List<Map<String, dynamic>>> readSql(
    String sql, {
    List<dynamic> parameters = const [],
  }) => _exclusive(
    () async =>
        (await _send({'op': 'sql', 'sql': sql, 'parameters': parameters})
                as List)
            .cast<Map<String, dynamic>>(),
  );
  Future<List<Map<String, dynamic>>> querySpec(
    String model,
    Map<String, dynamic> query,
  ) => _exclusive(
    () async =>
        (await _send({'op': 'querySpec', 'model': model, 'query': query})
                as List)
            .cast<Map<String, dynamic>>(),
  );
  Future<Map<String, dynamic>?> related(
    String model,
    Map<String, dynamic> identity,
    String relation,
  ) => _exclusive(
    () async =>
        await _send({
              'op': 'related',
              'key': {'model': model, 'identity': identity},
              'relation': relation,
            })
            as Map<String, dynamic>?,
  );
  Future<List<Map<String, dynamic>>> referencing(
    String model,
    Map<String, dynamic> identity,
    String source,
    String relation,
  ) => _exclusive(
    () async =>
        (await _send({
                  'op': 'referencing',
                  'key': {'model': model, 'identity': identity},
                  'source': source,
                  'relation': relation,
                })
                as List)
            .cast<Map<String, dynamic>>(),
  );
  Future<int> mutate(Map<String, dynamic> mutation) =>
      transaction((tx) => tx.mutate(mutation));
  Future<void> subscribe(String channel) {
    _liveGeneration++;
    return _exclusive(() async {
      await _send({'op': 'channel', 'channel': channel, 'subscribed': true});
      _channels.add(null);
      _work.add(null);
    });
  }

  Future<void> unsubscribe(String channel) {
    _liveGeneration++;
    return _exclusive(() async {
      await _send({'op': 'channel', 'channel': channel, 'subscribed': false});
      _channels.add(null);
      _work.add(null);
    });
  }

  Future<RuntimeConnection> connectLive(
    LiveTransport live, {
    void Function(Object)? onError,
    Future<void> Function()? refreshAuth,
  }) {
    final session = live.createSession();
    return _connect(
      session.push,
      live: session,
      onError: onError,
      refreshAuth: refreshAuth,
    );
  }

  Future<RuntimeConnection> connect(
    Transport transport, {
    void Function(Object)? onError,
    Future<void> Function()? refreshAuth,
  }) => _connect(transport, onError: onError, refreshAuth: refreshAuth);
  Future<RuntimeConnection> _connect(
    Transport transport, {
    LiveTransport? live,
    void Function(Object)? onError,
    Future<void> Function()? refreshAuth,
  }) async {
    if (_closed || _closing != null) throw StateError('client_closed');
    if (_connecting || _connection != null)
      throw StateError('connection already active');
    _connecting = true;
    final started = Completer<void>();
    _started = started;
    try {
      Future<void>? refreshing;
      Future<void> refresh() =>
          refreshing ??= Future<void>.sync(refreshAuth!).whenComplete(() {
            refreshing = null;
          });
      final connection = await RuntimeConnection.start(
        control: (event, now, entropy) => _exclusive(
          () => _send({
            'op': 'connection',
            'event': event,
            'now': now,
            'entropy': entropy,
          }),
        ),
        sync: (transport) => _startSync(transport, live != null),
        transport: transport,
        onError: onError,
        refreshAuth: refreshAuth == null ? null : refresh,
      );
      StreamSubscription<void>? channelSubscription;
      if (live != null) {
        Completer<void>? session;
        int streamEpoch = 0;
        void invalidate() {
          streamEpoch++;
          if (session?.isCompleted == false) session!.complete();
        }

        final streaming = await RuntimeConnection.start(
          control: (event, now, entropy) => _exclusive(
            () => _send({
              'op': 'connection',
              'lane': 'live',
              'event': event,
              'now': now,
              'entropy': entropy,
            }),
          ),
          sync: (request) async {
            await request('live', '');
          },
          transport: (kind, body) async {
            final epoch = ++streamEpoch;
            final current = Completer<void>();
            session = current;
            try {
              final snapshot = await _exclusive(
                () async => (await _send({'op': 'status'}), _liveGeneration),
              );
              final status = snapshot.$1 as Map;
              if (current.isCompleted ||
                  epoch != streamEpoch ||
                  (status['channels'] as List).isEmpty)
                return '';
              final cursors = {
                for (final scope in status['channels'] as List)
                  scope as String: (status['cursors'] as Map)[scope] ?? 0,
              };
              await live.stream(
                cursors,
                (page) => _exclusive(() async {
                  if (!current.isCompleted &&
                      epoch == streamEpoch &&
                      snapshot.$2 == _liveGeneration) {
                    await _send({'op': 'pull', 'page': page});
                    _work.add(null);
                  }
                }),
                current.future,
              );
              return '';
            } finally {
              if (!current.isCompleted) current.complete();
              if (identical(session, current)) session = null;
            }
          },
          onError: onError,
          refreshAuth: refreshAuth == null ? null : refresh,
        );
        channelSubscription = _channels.stream.listen((_) {
          invalidate();
          unawaited(
            streaming.wake().catchError((Object error) {
              onError?.call(error);
            }),
          );
        });
        connection.attachLive(streaming, () {
          invalidate();
          live.cancelPush();
        });
      }
      final subscription = _work.stream.listen((_) {
        unawaited(
          connection.wake().catchError((Object error) {
            onError?.call(error);
          }),
        );
      });
      _connection = connection;
      unawaited(
        connection.closed.then((_) async {
          await subscription.cancel();
          await channelSubscription?.cancel();
          if (identical(_connection, connection)) _connection = null;
        }),
      );
      return connection;
    } finally {
      _connecting = false;
      started.complete();
    }
  }

  /// Rust selects actions and settlement; transport only performs the request.
  Future<void> sync(
    Future<String> Function(String kind, String body) transport,
  ) => _startSync(transport, false);
  Future<void> _startSync(Transport transport, bool pushOnly) =>
      _syncing ??= _runSync(transport, pushOnly).whenComplete(() {
        _syncing = null;
      });
  Future<void> _runSync(
    Future<String> Function(String kind, String body) transport,
    bool pushOnly,
  ) async {
    await _exclusive(() => _send({'op': 'startSync', 'pushOnly': pushOnly}));
    while (true) {
      final action = await _exclusive(() => _send({'op': 'next'}));
      if (action == null) return;
      final response = await transport(
        action['kind'] as String,
        action['body'] as String,
      );
      await _exclusive(
        () => _send({'op': 'complete', 'response': jsonDecode(response)}),
      );
    }
  }

  Future<void> runPrerequisites(
    Map<String, Future<void> Function(Map<String, dynamic>)> handlers,
  ) => _tasks ??= _runPrerequisites(handlers).whenComplete(() {
    _tasks = null;
  });
  Future<void> _runPrerequisites(
    Map<String, Future<void> Function(Map<String, dynamic>)> handlers,
  ) async {
    while (true) {
      final tasks = (await pendingTasks()).where(
        (task) => task['state'] == 'pending',
      );
      if (tasks.isEmpty) return;
      final task = tasks.first;
      final handler = handlers[task['name']];
      if (handler == null)
        throw StateError('Missing prerequisite handler: ${task['name']}');
      try {
        await handler(task['arguments'] as Map<String, dynamic>);
        await setReadiness(task['key'] as String, 'ready');
      } catch (_) {
        await setReadiness(task['key'] as String, 'failed');
      }
    }
  }

  Future<String?> freeze() =>
      _exclusive(() async => await _send({'op': 'freeze'}) as String?);
  Future<void> acknowledge(int sequence, Map<String, dynamic> receipt) =>
      _exclusive(() async {
        await _send({'op': 'ack', 'sequence': sequence, 'receipt': receipt});
      });
  Future<Map<String, dynamic>> applyPull(Map<String, dynamic> page) =>
      _exclusive(
        () async =>
            (await _send({'op': 'pull', 'page': page})) as Map<String, dynamic>,
      );
  Future<Map<String, dynamic>> recordStatus(
    String model,
    Map<String, dynamic> identity,
  ) => _exclusive(
    () async =>
        await _send({
              'op': 'recordStatus',
              'key': {'model': model, 'identity': identity},
            })
            as Map<String, dynamic>,
  );
  Future<Map<String, dynamic>> status() => _exclusive(
    () async => (await _send({'op': 'status'})) as Map<String, dynamic>,
  );
  Future<List<Map<String, dynamic>>> pendingTasks() => _exclusive(
    () async =>
        (await _send({'op': 'tasks'}) as List).cast<Map<String, dynamic>>(),
  );
  Future<void> setReadiness(String key, String state) => _exclusive(() async {
    await _send({'op': 'readiness', 'key': key, 'state': state});
    _work.add(null);
  });
  Future<void> drop(int ordinal) => _exclusive(() async {
    await _send({'op': 'drop', 'ordinal': ordinal});
    _work.add(null);
  });
  Future<void> dismissRejection(int ordinal) => _exclusive(() async {
    await _send({'op': 'dismiss', 'ordinal': ordinal});
  });
  Stream<List<Map<String, dynamic>>> watch(
    String model, {
    Map<String, dynamic> where = const {},
  }) {
    return Stream<List<Map<String, dynamic>>>.multi((sink) {
      String? previous;
      bool cancelled = false;
      Future<void> pending = Future<void>.value();
      void refresh() {
        pending = pending.then((_) async {
          if (cancelled) return;
          try {
            final rows = await query(model, where: where);
            final value = jsonEncode(rows);
            if (!cancelled && value != previous) {
              previous = value;
              sink.add(rows);
            }
          } catch (e, st) {
            if (!cancelled) sink.addError(e, st);
          }
        });
      }

      final sub = _changes.stream.listen((_) => refresh(), onDone: sink.close);
      refresh();
      sink.onCancel = () async {
        cancelled = true;
        await sub.cancel();
      };
    });
  }

  Future<void> close() => _closing ??= _finishClose();

  Future<void> _finishClose() async {
    await _started?.future;
    await _connection?.close();
    await _exclusive(() async {
      if (_closed) return;
      try {
        await _send({'op': 'close'});
      } finally {
        _closed = true;
        _worker.send(null);
        _isolate.kill();
        await _changes.close();
        await _work.close();
        await _channels.close();
      }
    });
  }
}

class Transaction implements WritePort {
  final Client _client;
  bool _open = true;
  Transaction._(this._client);
  Future<void> _tail = Future<void>.value();
  int _pending = 0;
  Object? _failure;
  Object? _structural;
  final Object _zoneKey = Object();
  Object? _active;
  final Set<Future<dynamic>> _scopes = {};
  Future<dynamic> _queue(Map<String, dynamic> request) {
    _pending++;
    final work = _tail.then(
      (_) => _client._send({...request, 'transaction': true}),
    );
    _tail = work.then<void>(
      (_) {
        _pending--;
      },
      onError: (Object error, StackTrace stack) {
        _pending--;
        _failure ??= error;
      },
    );
    return work;
  }

  Future<dynamic> _send(Map<String, dynamic> request) {
    if (!_open) return Future.error(StateError('transaction_closed'));
    if (_active != null && Zone.current[_zoneKey] != _active) {
      _structural = StateError('overlapping savepoint work');
      return Future.error(_structural!);
    }
    return _queue(request);
  }

  Future<void> _finish() async {
    final outstanding = _pending > 0 || _scopes.isNotEmpty;
    _open = false;
    await _tail;
    if (_structural != null) throw _structural!;
    if (outstanding) throw StateError('unawaited transaction operation');
    if (_failure != null) throw _failure!;
  }

  Future<Map<String, dynamic>?> read(
    String model,
    Map<String, dynamic> identity,
  ) async =>
      (await _send({
            'op': 'read',
            'key': {'model': model, 'identity': identity},
          }))
          as Map<String, dynamic>?;
  Future<List<Map<String, dynamic>>> query(
    String model, {
    Map<String, dynamic> where = const {},
  }) async =>
      (await _send({'op': 'query', 'model': model, 'filter': where}) as List)
          .cast<Map<String, dynamic>>();
  Future<List<Map<String, dynamic>>> readSql(
    String sql, {
    List<dynamic> parameters = const [],
  }) async =>
      (await _send({'op': 'sql', 'sql': sql, 'parameters': parameters}) as List)
          .cast<Map<String, dynamic>>();
  Future<List<Map<String, dynamic>>> querySpec(
    String model,
    Map<String, dynamic> query,
  ) async =>
      (await _send({'op': 'querySpec', 'model': model, 'query': query}) as List)
          .cast<Map<String, dynamic>>();
  Future<Map<String, dynamic>?> related(
    String model,
    Map<String, dynamic> identity,
    String relation,
  ) async =>
      await _send({
            'op': 'related',
            'key': {'model': model, 'identity': identity},
            'relation': relation,
          })
          as Map<String, dynamic>?;
  Future<List<Map<String, dynamic>>> referencing(
    String model,
    Map<String, dynamic> identity,
    String source,
    String relation,
  ) async =>
      (await _send({
                'op': 'referencing',
                'key': {'model': model, 'identity': identity},
                'source': source,
                'relation': relation,
              })
              as List)
          .cast<Map<String, dynamic>>();
  Future<void> direct(Map<String, dynamic> operation) async {
    await _send({'op': 'direct', 'operation': operation});
  }

  Future<int> mutate(Map<String, dynamic> mutation) async =>
      await _send({'op': 'enqueue', 'mutation': mutation}) as int;
  Future<T> savepoint<T>(Future<T> Function() body) {
    if (!_open) return Future.error(StateError('transaction_closed'));
    if (_active != null && Zone.current[_zoneKey] != _active) {
      _structural = StateError('overlapping savepoints');
      return Future.error(_structural!);
    }
    final parent = _active;
    final token = Object();
    _active = token;
    final failure = _failure;
    final run = runZoned(() async {
      await _queue({'op': 'savepoint'});
      try {
        if (!_open) throw StateError('transaction_closed');
        final result = await body();
        await _tail;
        if (!_open) throw StateError('transaction_closed');
        if (_active != token) {
          _structural = StateError('unawaited nested savepoint');
          throw _structural!;
        }
        if (_failure != failure) throw _failure!;
        if (_structural != null) throw _structural!;
        await _queue({'op': 'release'});
        return result;
      } catch (error, stack) {
        await _tail;
        if (_open && _structural == null) {
          if (_active != token) {
            _structural = StateError('unawaited nested savepoint');
            throw _structural!;
          }
          await _queue({'op': 'rollbackSavepoint'});
          _failure = failure;
        }
        Error.throwWithStackTrace(error, stack);
      } finally {
        if (_active == token) _active = parent;
      }
    }, zoneValues: {_zoneKey: token});
    _scopes.add(run);
    unawaited(
      run.then<void>(
        (_) {
          _scopes.remove(run);
        },
        onError: (Object _, StackTrace __) {
          _scopes.remove(run);
        },
      ),
    );
    return run;
  }
}
