import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:local_sync/local_sync.dart';

import '../../local_sync_conformance.dart';
import 'rest_ws_conformance.dart';

/// The mechanics every cross-language scenario needs and none of them owns: a
/// throwaway database, a real client pointed at a host the TypeScript harness
/// started, and one JSON object on stdout for that harness to assert on.
///
/// What a scenario *does* is not here. A contract owns its own scenarios, so
/// the protocol suite and the end-to-end suite can move independently without
/// meeting in a shared switch statement.

const conformanceClientId = '5d6c1f20-9105-4f7e-89d7-163fa5dcbb84';
const conformanceUserId = '1c1a5f4e-2b3c-4d5e-8f90-a1b2c3d4e5f6';
const conformanceSpaceId = 'f0e1d2c3-b4a5-4968-8778-695a4b3c2d1e';
const conformanceDeniedBookId = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
const conformanceBookAId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const conformanceBookBId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const conformanceBookAMomentId = '11111111-1111-4111-8111-111111111111';
const conformanceBookBNoteId = '22222222-2222-4222-8222-222222222222';
const conformanceUserScope = 'User:$conformanceUserId';
const conformanceSpaceScope = 'Space:$conformanceSpaceId';
const conformanceBookAScope = 'Book:$conformanceBookAId';
const conformanceBookBScope = 'Book:$conformanceBookBId';
const conformanceDeniedBookScope = 'Book:$conformanceDeniedBookId';

/// The two rows every family hangs off: a Moment lives under a Space, which
/// lives under a User, and the local store enforces both.
StoredMutationOperation conformanceUserRow({int ordinal = 1}) =>
    StoredMutationOperation(
      mutationOrdinal: ordinal,
      position: 0,
      model: 'User',
      identityJson: jsonEncode({'id': conformanceUserId}),
      operation: 'create',
      valuesJson: jsonEncode({'handle': 'steve'}),
      isUplink: true,
    );

StoredMutationOperation conformanceSpaceRow({int ordinal = 2}) =>
    StoredMutationOperation(
      mutationOrdinal: ordinal,
      position: 0,
      model: 'Space',
      identityJson: jsonEncode({'id': conformanceSpaceId}),
      operation: 'create',
      valuesJson: jsonEncode({
        'ownerId': conformanceUserId,
        'name': 'Family',
        'kind': 'group',
      }),
      isUplink: true,
    );

/// The act a fixture operation belongs to.
///
/// There are no anonymous writes left (CAP-444): every operation on the wire
/// rides inside a named act, so a fixture built row by row has to say which
/// one. These fixtures are seeds and refusals — one operation, one act — so
/// the mapping is by `(Model, operation)` and nothing here composes.
StoredMutation conformanceRecordFor(StoredMutationOperation row) {
  final name = switch ((row.model, row.operation)) {
    ('User', 'create') => 'RegisterUser',
    ('Space', 'create') => 'CreateSpace',
    ('Space', 'update') => 'RenameSpace',
    ('Space', 'delete') => 'DeleteSpace',
    ('AccountState', 'create') => 'SaveAccountState',
    ('Moment', 'create') => 'WriteMoment',
    ('Moment', 'update') => 'ReviseMoment',
    ('Moment', 'delete') => 'DiscardMoment',
    ('ScalarSample', 'create') => 'RecordSample',
    ('ScalarSample', 'update') => 'ReviseSample',
    ('LocalNote', 'create') => 'PublishNote',
    _ => throw ArgumentError(
      'no conformance act writes ${row.model}.${row.operation}',
    ),
  };
  return StoredMutation(
    ordinal: row.mutationOrdinal,
    name: name,
    legacyFifo: false,
  );
}

/// One batch sent and answered — the status the far side gave, the body it
/// gave, and which ordinals the answer is allowed to speak for.
final class SentBatch {
  SentBatch(this.status, this.body, this.ordinals);
  final int status;
  final Uint8List body;
  final Set<int> ordinals;
}

/// The live client, with the two calls every scenario makes.
final class WireSession {
  WireSession(this.client, this.scope, this.port);

  final RestWsConformanceClient client;
  final LocalDatabaseScope scope;

  /// Where the host is listening. A scenario that needs a SECOND client — its
  /// own runtime, or a channel it may close and open again — builds one from
  /// this rather than reaching into the one it was handed.
  final int port;

  LocalSyncTransport get transport => client.transport;
  LocalSyncJsonCodec get codec => client.codec;

  Future<SentBatch> send(
    int batchSequence,
    List<StoredMutationOperation> mutations,
  ) async {
    final response = await client.transport.sendUplink(
      client.codec.encodeUplinkRequest(
        clientId: conformanceClientId,
        batchSequence: batchSequence,
        mutations: mutations,
        records: {
          for (final row in mutations)
            row.mutationOrdinal: conformanceRecordFor(row),
        },
      ),
    );
    return SentBatch(
      response.statusCode,
      localSyncResponseBody(response),
      mutations.map((row) => row.mutationOrdinal).toSet(),
    );
  }

  /// Sends a batch and reads the answer, which every scenario does before it
  /// can look at anything else.
  Future<UplinkResponse> settle(
    int batchSequence,
    List<StoredMutationOperation> mutations,
  ) async {
    final sent = await send(batchSequence, mutations);
    return client.codec.decodeUplinkResponse(
      sent.body,
      requestMutationIds: sent.ordinals,
    );
  }

  /// The page the cursor asks for, decoded.
  Future<DownlinkPage> pull(int afterSyncId, {String? scope}) async =>
      client.codec.decodeDownlinkPage(
        localSyncResponseBody(
          await client.transport.fetchDownlink(
            client.codec.encodeDownlinkRequest(
              clientId: conformanceClientId,
              scope: scope ?? conformanceUserScope,
              afterSyncId: afterSyncId,
            ),
          ),
        ),
      );
}

/// What a contract's executable supplies: the answer to one named scenario.
typedef WireScenario =
    Future<Map<String, Object?>> Function(WireSession session, String scenario);

/// Opens a throwaway client against the port in `arguments[0]`, runs the
/// scenario named in `arguments[1]` with the comma-separated credentials in
/// `arguments[2]`, and prints the result the harness reads back.
///
/// [clientBuild] is the build the live channel declares. The contract supplies
/// it, because which scenario stands on which side of a host's floor is a
/// scenario's business and never this file's.
Future<void> runWireScenario(
  List<String> arguments,
  WireScenario run, {
  int? clientBuild,
}) async {
  final port = int.parse(arguments[0]);
  final scenario = arguments[1];
  final tokens = arguments.length > 2
      ? arguments[2].split(',')
      : <String>[conformanceToken];

  final directory = await Directory.systemTemp.createTemp('local_sync_wire_');
  final database = await localSyncDatabaseDriver(
    path: '${directory.path}/local-sync.sqlite',
  ).open();
  final scope = LocalDatabaseScope(database);
  final registry = buildModelRegistry(scope);
  await MutationQueue(
    scope,
    registry: registry,
  ).initialize(conformanceClientId);

  var issued = 0;
  final client = RestWsConformanceClient.connect(
    port: port,
    database: scope,
    clientBuild: clientBuild,
    getAccessToken: () async {
      final token = tokens[issued < tokens.length ? issued : tokens.length - 1];
      issued += 1;
      return token;
    },
  );

  try {
    final result = await run(WireSession(client, scope, port), scenario);
    stdout.writeln(jsonEncode({...result, 'tokensIssued': issued}));
  } on LocalSyncTransportFailure catch (failure) {
    stdout.writeln(
      jsonEncode({
        'failure': failure.runtimeType.toString(),
        'status': failure.status,
        'tokensIssued': issued,
      }),
    );
  } finally {
    await client.close();
    await database.close();
    await directory.delete(recursive: true);
  }
}
