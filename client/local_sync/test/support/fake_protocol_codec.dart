import 'dart:convert';
import 'dart:typed_data';

import 'package:local_sync/local_sync.dart';
import 'package:local_sync/src/downlink/scopes.dart';

const fakeScope = 'User:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

/// A readable stand-in wire format for the worker tests. The workers are
/// indifferent to the encoding — they hand the codec bytes and take bytes
/// back — so their tests use one they can assert against by eye.
final class FakeProtocolCodec implements LocalSyncProtocolCodec {
  const FakeProtocolCodec();

  @override
  Uint8List encodeUplinkRequest({
    required String clientId,
    required int batchSequence,
    required List<StoredMutationOperation> mutations,
    Map<int, StoredMutation> records = const {},
  }) {
    for (final mutation in mutations) {
      // The one thing this fake still judges: an operation the queue could
      // not have meant. It used to judge a schema version instead — CAP-481
      // deleted that number, and the worker's "invalid durable data is
      // terminal" rule needs SOME durable defect to be terminal about.
      if (!const {'create', 'update', 'delete'}.contains(mutation.operation)) {
        throw UplinkDataException(
          'unknown mutation operation "${mutation.operation}"',
        );
      }
    }
    return encodeBytes({
      'clientId': clientId,
      'batchSequence': batchSequence,
      'mutations': [
        for (final mutation in mutations)
          {
            'ordinal': mutation.mutationOrdinal,
            'model': mutation.model,
            'values': mutation.valuesJson,
          },
      ],
    });
  }

  @override
  UplinkResponse decodeUplinkResponse(
    Uint8List bytes, {
    required Set<int> requestMutationIds,
  }) {
    final map = decodeBytes(bytes);
    final requiredSyncId = map['requiredSyncId'];
    final rejections = map['rejections'];
    if (requiredSyncId is! int || rejections is! List) {
      throw const UplinkDataException('invalid Uplink response');
    }
    final checkpoint = UplinkCheckpoint(
      scope: fakeScope,
      syncId: requiredSyncId,
    );
    return UplinkResponse(
      requiredCheckpoints: [checkpoint],
      legacyPrincipalCheckpoint: checkpoint,
      rejections: [
        for (final rejection in rejections.cast<Map<String, Object?>>())
          UplinkMutationRejection(
            mutationId: rejection['ordinal']! as int,
            code: rejection['code']! as String,
          ),
      ],
    );
  }

  @override
  Uint8List encodeDownlinkRequest({
    required String clientId,
    required String scope,
    required int afterSyncId,
  }) => encodeBytes({
    'clientId': clientId,
    'scope': scope,
    'afterSyncId': afterSyncId,
  });

  @override
  DownlinkPage decodeDownlinkPage(Uint8List bytes) {
    final map = decodeBytes(bytes);
    final scope = _scope(map['scope']);
    final fromSyncId = map['fromSyncId'];
    final throughSyncId = map['throughSyncId'];
    final changes = map['changes'];
    if (fromSyncId is! int || throughSyncId is! int || changes is! List) {
      throw const DownlinkDataException('invalid Downlink page');
    }
    return DownlinkPage(
      scope: scope,
      fromSyncId: fromSyncId,
      throughSyncId: throughSyncId,
      changes: [
        for (final change in changes.cast<Map<String, Object?>>())
          AddressedModelChange(syncId: change['syncId']! as int, raw: change),
      ],
    );
  }

  @override
  Uint8List encodeDownlinkSubscribe(Iterable<String> scopes) =>
      encodeBytes({'type': 'subscribe', 'scopes': normalizeScopes(scopes)});

  @override
  DownlinkLiveMessage decodeDownlinkLiveMessage(Uint8List bytes) {
    final map = decodeBytes(bytes);
    if (map.containsKey('type')) {
      if (map['type'] != 'subscribed' || map['scopes'] is! List) {
        throw const DownlinkDataException('invalid live acknowledgement');
      }
      final rejections = map['rejections'];
      if (rejections is! List) {
        throw const DownlinkDataException('invalid live rejections');
      }
      return DownlinkSubscribed(
        scopes: (map['scopes']! as List<Object?>).map(_scope),
        rejections: rejections.map((entry) {
          if (entry is! Map) {
            throw const DownlinkDataException('invalid live rejection');
          }
          final rejection = entry.cast<String, Object?>();
          return DownlinkScopeRejection(
            scope: _scope(rejection['scope']),
            code: rejection['code']! as String,
          );
        }),
      );
    }
    return DownlinkLivePage(decodeDownlinkPage(bytes));
  }
}

String _scope(Object? value) {
  if (value is! String) throw const DownlinkDataException('invalid scope');
  return value;
}

Uint8List encodeBytes(Map<String, Object?> value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

Map<String, Object?> decodeBytes(Uint8List bytes) {
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } on FormatException catch (error) {
    throw DownlinkDataException('undecodable page', error);
  }
  if (decoded is! Map) throw const DownlinkDataException('page is not a map');
  return decoded.cast<String, Object?>();
}
