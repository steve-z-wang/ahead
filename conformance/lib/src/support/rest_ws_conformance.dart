import 'package:local_sync/local_sync.dart';

import '../../local_sync_conformance.dart';

/// The credential the Conformance host accepts.
const conformanceToken = 'conformance-token';

/// The credential it refuses once, so the auth-refresh convention has
/// something to heal from.
const staleConformanceToken = 'stale-token';

/// A real client against a real server: the shipped transport, the shipped
/// codec, and the generated registry — nothing stands in for anything.
///
/// This is what makes the suite cross-language rather than two suites that
/// happen to agree: the Dart runtime writes the bytes and the TypeScript host
/// reads them, so a disagreement about the wire is a failure here and nowhere
/// else.
final class RestWsConformanceClient {
  RestWsConformanceClient._({
    required this.transport,
    required this.codec,
    required this.registry,
  });

  /// [clientBuild] is what the live channel declares as `?build=`. Naming none
  /// is what an ordinary scenario does, and what the host's floor passes.
  factory RestWsConformanceClient.connect({
    required int port,
    required LocalDatabaseScope database,
    required Future<String> Function() getAccessToken,
    LocalSyncSocketConnector? connect,
    int? clientBuild,
  }) {
    final registry = buildModelRegistry(database);
    return RestWsConformanceClient._(
      transport: AuthRefreshingTransport(
        provider: ({bool forceRefresh = false}) => getAccessToken(),
        inner: (token) => RestWsTransport(
          baseUri: Uri.parse('http://127.0.0.1:$port/'),
          getAccessToken: token,
          connect: connect,
          clientBuild: clientBuild,
          sleep: (_) async {},
        ),
      ),
      codec: LocalSyncJsonCodec(registry: registry),
      registry: registry,
    );
  }

  final LocalSyncTransport transport;
  final LocalSyncJsonCodec codec;
  final ModelRegistry registry;

  Future<void> close() => transport.close();
}
