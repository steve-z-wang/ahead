import 'dart:convert';
import 'dart:typed_data';

import '../downlink/downlink_protocol.dart';
import '../downlink/scopes.dart';
import '../mutation/model_mutation.dart';
import '../mutation/mutation_store.dart';
import '../schema/model_registry.dart';
import '../storage/local_value_codec.dart';
import '../uplink/uplink_mutation_normalizer.dart';
import '../uplink/uplink_protocol.dart';
import 'local_sync_protocol_codec.dart';

/// The wire format: JSON envelopes carrying a Model as a name and an opaque
/// object of values.
///
/// The codec knows no Model. Every rule about what a mutation may say still
/// comes from the shared normalizer, and every rule about what a change means
/// still comes from the Downlink decoders; this class only moves values across
/// the JSON boundary — which is why nothing here is generated.
///
/// Keys are written in a fixed order so two encodings of one batch are the
/// same bytes, and unknown keys are ignored on read so the wire can gain a
/// field without a client of the previous shape refusing the page.
final class LocalSyncJsonCodec implements LocalSyncProtocolCodec {
  LocalSyncJsonCodec({
    required this.registry,
    this.codec = const LocalValueCodec(),
  });

  final ModelRegistry registry;
  final LocalValueCodec codec;

  @override
  Uint8List encodeUplinkRequest({
    required String clientId,
    required int batchSequence,
    required List<StoredMutationOperation> mutations,
    Map<int, StoredMutation> records = const {},
  }) {
    // An act's companion operations stay in the queue — rollback needs them —
    // but never reach the wire: the server has no notion they exist. The
    // projection happens here, where a batch becomes a body.
    final sent = mutations.where((row) => row.isUplink).toList();
    final normalized =
        UplinkMutationNormalizer(
          registry: registry,
          codec: codec,
        ).normalizeBatch(
          clientId: clientId,
          batchSequence: batchSequence,
          mutations: sent,
          records: records,
        );
    // One named act is one wire element, whatever it is spelled with: the
    // operations ride inside it, in the order the slots declared (CAP-439).
    final elements = <Map<String, Object?>>[];
    final started = <int>{};
    for (final mutation in normalized) {
      final ordinal = mutation.mutationOrdinal;
      if (!started.add(ordinal)) continue;
      final record = records[ordinal];
      if (record == null) {
        throw UplinkDataException('missing mutation record $ordinal');
      }
      elements.add({
        'ordinal': record.legacyWireOrdinal ?? record.ordinal,
        'name': record.name,
        if (record.version != null) 'version': record.version,
        'operations': [
          for (final operation in normalized)
            if (operation.mutationOrdinal == ordinal)
              _encodeOperation(operation),
        ],
      });
    }
    return _write({
      'clientId': clientId,
      'batchSequence': batchSequence,
      'mutations': elements,
    });
  }

  @override
  UplinkResponse decodeUplinkResponse(
    Uint8List bytes, {
    required Set<int> requestMutationIds,
  }) {
    final response = _readObject(
      bytes,
      (message) => UplinkDataException(message),
    );
    final requiredSyncId = _safeInteger(
      response['requiredSyncId'],
      'requiredSyncId',
      (message) => UplinkDataException(message),
    );
    final requiredScope = _decodeScope(
      response['requiredScope'],
      (message) => UplinkDataException(message),
    );
    final legacyPrincipalCheckpoint = UplinkCheckpoint(
      scope: requiredScope,
      syncId: requiredSyncId,
    );
    final requiredCheckpoints = <UplinkCheckpoint>[];
    if (response.containsKey('requiredCheckpoints')) {
      final entries = _list(
        response['requiredCheckpoints'],
        'requiredCheckpoints',
        (message) => UplinkDataException(message),
      );
      if (entries.isEmpty) {
        throw const UplinkDataException(
          'requiredCheckpoints must not be empty',
        );
      }
      final seenScopes = <String>{};
      for (final entry in entries) {
        final checkpoint = _object(
          entry,
          'required checkpoint',
          (message) => UplinkDataException(message),
        );
        final scope = _decodeScope(
          checkpoint['scope'],
          (message) => UplinkDataException(message),
        );
        if (!seenScopes.add(scope)) {
          throw UplinkDataException(
            'duplicate required checkpoint scope',
            scope.toString(),
          );
        }
        requiredCheckpoints.add(
          UplinkCheckpoint(
            scope: scope,
            syncId: _safeInteger(
              checkpoint['syncId'],
              'required checkpoint syncId',
              (message) => UplinkDataException(message),
            ),
          ),
        );
      }
    } else {
      requiredCheckpoints.add(legacyPrincipalCheckpoint);
    }
    final rejections = <UplinkMutationRejection>[];
    final seen = <int>{};
    for (final entry in _list(
      response['rejections'],
      'rejections',
      (message) => UplinkDataException(message),
    )) {
      final rejection = _object(
        entry,
        'rejection',
        (message) => UplinkDataException(message),
      );
      final ordinal = _safeInteger(
        rejection['ordinal'],
        'rejection ordinal',
        (message) => UplinkDataException(message),
      );
      if (!requestMutationIds.contains(ordinal)) {
        throw UplinkDataException('rejection $ordinal was not requested');
      }
      if (!seen.add(ordinal)) {
        throw UplinkDataException('duplicate rejection $ordinal');
      }
      final code = rejection['code'];
      if (code is! String || code.isEmpty) {
        throw const UplinkDataException('rejection code must not be empty');
      }
      rejections.add(UplinkMutationRejection(mutationId: ordinal, code: code));
    }
    return UplinkResponse(
      requiredCheckpoints: requiredCheckpoints,
      legacyPrincipalCheckpoint: legacyPrincipalCheckpoint,
      rejections: rejections,
    );
  }

  @override
  Uint8List encodeDownlinkRequest({
    required String clientId,
    required String scope,
    required int afterSyncId,
  }) {
    requireUuid(clientId, 'clientId');
    if (afterSyncId < 0 || afterSyncId > maxSafeUplinkInteger) {
      throw const DownlinkDataException(
        'afterSyncId must be a non-negative safe integer',
      );
    }
    return _write({
      'clientId': clientId,
      'scope': scope,
      'fromCursor': afterSyncId,
    });
  }

  @override
  DownlinkPage decodeDownlinkPage(Uint8List bytes) {
    final page = _readObject(
      bytes,
      (message) => DownlinkDataException(message),
    );
    final scope = _decodeScope(
      page['scope'],
      (message) => DownlinkDataException(message),
    );
    final fromCursor = _safeInteger(
      page['fromCursor'],
      'fromCursor',
      (message) => DownlinkDataException(message),
    );
    final toCursor = _safeInteger(
      page['toCursor'],
      'toCursor',
      (message) => DownlinkDataException(message),
    );
    if (toCursor < fromCursor) {
      throw const DownlinkDataException('toCursor must not precede fromCursor');
    }
    final changes = <AddressedModelChange>[];
    var previous = fromCursor;
    for (final entry in _list(
      page['changes'],
      'changes',
      (message) => DownlinkDataException(message),
    )) {
      final change = _decodeChange(entry);
      if (change.syncId <= previous) {
        throw const DownlinkDataException(
          'changes must have strictly increasing syncIds',
        );
      }
      if (change.syncId > toCursor) {
        throw const DownlinkDataException('change exceeds toCursor');
      }
      previous = change.syncId;
      changes.add(change);
    }
    return DownlinkPage(
      scope: scope,
      fromSyncId: fromCursor,
      throughSyncId: toCursor,
      changes: changes,
    );
  }

  @override
  Uint8List encodeDownlinkSubscribe(Iterable<String> scopes) {
    late final List<String> active;
    try {
      active = normalizeScopes(scopes);
    } on FormatException catch (error) {
      throw DownlinkDataException(error.message, error.source, error.offset);
    }
    return _write({'type': 'subscribe', 'scopes': active});
  }

  @override
  DownlinkLiveMessage decodeDownlinkLiveMessage(Uint8List bytes) {
    final envelope = _readObject(
      bytes,
      (message) => DownlinkDataException(message),
    );
    if (envelope.containsKey('type')) {
      if (envelope['type'] != 'subscribed') {
        throw const DownlinkDataException(
          'live acknowledgement type must be subscribed',
        );
      }
      final rawScopes = _list(
        envelope['scopes'],
        'scopes',
        (message) => DownlinkDataException(message),
      );
      final rawRejections = _list(
        envelope['rejections'],
        'rejections',
        (message) => DownlinkDataException(message),
      );
      try {
        return DownlinkSubscribed(
          scopes: rawScopes.map(
            (scope) => _decodeScope(
              scope,
              (message) => DownlinkDataException(message),
            ),
          ),
          rejections: rawRejections.map((entry) {
            final rejection = _object(
              entry,
              'scope rejection',
              (message) => DownlinkDataException(message),
            );
            final code = rejection['code'];
            if (code is! String || code.isEmpty) {
              throw const DownlinkDataException(
                'scope rejection code must not be empty',
              );
            }
            return DownlinkScopeRejection(
              scope: _decodeScope(
                rejection['scope'],
                (message) => DownlinkDataException(message),
              ),
              code: code,
            );
          }),
        );
      } on FormatException catch (error) {
        if (error is DownlinkDataException) rethrow;
        throw DownlinkDataException(error.message, error.source, error.offset);
      }
    }
    return DownlinkLivePage(decodeDownlinkPage(bytes));
  }

  /// One operation, addressed but not positioned: inside a named act the
  /// position is the act's, and the slot order is the operations' own order.
  Map<String, Object?> _encodeOperation(NormalizedUplinkMutation mutation) {
    return {
      'model': mutation.model,
      'op': mutation.operation.name,
      'identity': mutation.identity,
      // A delete says nothing but which row; an update names only the fields it
      // touches, and a key held at null is the clear.
      if (mutation.operation != MutationOperation.delete)
        'values': mutation.values,
    };
  }

  /// Structure only: which row changed and whether it still exists. What the
  /// values mean is [ModelChangeDecoder]'s, so the shape handed on is the one
  /// it already reads.
  AddressedModelChange _decodeChange(Object? entry) {
    final change = _object(
      entry,
      'change',
      (message) => DownlinkDataException(message),
    );
    final syncId = _safeInteger(
      change['syncId'],
      'change syncId',
      (message) => DownlinkDataException(message),
    );
    final model = change['model'];
    if (model is! String || model.isEmpty) {
      throw const DownlinkDataException(
        'change model must be a non-empty name',
      );
    }
    final identity = _object(
      change['identity'],
      'change identity',
      (message) => DownlinkDataException(message),
    );
    if (!change.containsKey('state')) {
      throw const DownlinkDataException('change must carry a state');
    }
    final state = change['state'];
    // Absence is the whole delete signal: a row the viewer may no longer read
    // reaches them the same way a deleted one does.
    if (state == null) {
      return AddressedModelChange(
        syncId: syncId,
        raw: {
          'syncId': syncId,
          'model': model,
          'operation': 'delete',
          'id': identity,
        },
      );
    }
    return AddressedModelChange(
      syncId: syncId,
      raw: {
        'syncId': syncId,
        'model': model,
        'operation': 'upsert',
        'id': identity,
        'data': _object(
          state,
          'change state',
          (message) => DownlinkDataException(message),
        ),
      },
    );
  }
}

String _decodeScope(
  Object? value,
  FormatException Function(String message) fail,
) {
  if (value is! String) throw fail('scope must be a string');
  return value;
}

Uint8List _write(Object? value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

Map<String, Object?> _readObject(
  Uint8List bytes,
  FormatException Function(String message) fail,
) {
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } on FormatException catch (error) {
    throw fail('envelope is not JSON: ${error.message}');
  }
  return _object(decoded, 'envelope', fail);
}

Map<String, Object?> _object(
  Object? value,
  String path,
  FormatException Function(String message) fail,
) {
  if (value is! Map) throw fail('$path must be a JSON object');
  try {
    return value.cast<String, Object?>();
  } on TypeError {
    throw fail('$path must have string keys');
  }
}

List<Object?> _list(
  Object? value,
  String path,
  FormatException Function(String message) fail,
) {
  if (value is! List) throw fail('$path must be a JSON array');
  return value;
}

int _safeInteger(
  Object? value,
  String path,
  FormatException Function(String message) fail,
) {
  if (value is! int || value < 0 || value > maxSafeUplinkInteger) {
    throw fail('$path must be a non-negative safe integer');
  }
  return value;
}
