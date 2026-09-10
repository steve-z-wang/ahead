import 'local_sync_transport.dart';

abstract interface class LocalSyncBackgroundWorker {
  void start();

  Future<void> close();
}

abstract interface class LocalSyncDownlinkWorker
    implements LocalSyncBackgroundWorker {
  Future<void> replaceScopes(Iterable<String> scopes);
}

final class LocalSyncLifecycle {
  LocalSyncLifecycle({
    required this.uplinkWorker,
    required this.downlinkWorker,
    required this.transport,
    required this.bindLegacyCheckpointScope,
  });

  final LocalSyncBackgroundWorker uplinkWorker;
  final LocalSyncDownlinkWorker downlinkWorker;
  final LocalSyncTransport transport;
  final Future<void> Function(Iterable<String> scopes)
  bindLegacyCheckpointScope;
  bool _workersStarted = false;

  Future<void> replaceScopes(Iterable<String> scopes) async {
    if (_workersStarted) {
      await downlinkWorker.replaceScopes(scopes);
      return;
    }

    final desired = scopes.toList(growable: false);
    if (desired.isEmpty) return;
    await bindLegacyCheckpointScope(desired);
    await downlinkWorker.replaceScopes(desired);

    // Subscribe both workers before opening the channel, so neither misses the
    // first connection. Once started, the runtime owns them until close.
    _workersStarted = true;
    downlinkWorker.start();
    uplinkWorker.start();
    await transport.start();
  }

  Future<void> close(Future<void> Function() closeDatabase) async {
    try {
      await downlinkWorker.close();
    } finally {
      try {
        await uplinkWorker.close();
      } finally {
        try {
          await transport.close();
        } finally {
          await closeDatabase();
        }
      }
    }
  }

  static Future<void> closeAfterOpenFailure({
    required LocalSyncTransport transport,
    required Future<void> Function() closeDatabase,
  }) async {
    try {
      await transport.close();
    } finally {
      await closeDatabase();
    }
  }
}
