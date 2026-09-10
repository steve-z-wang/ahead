import 'dart:typed_data';

import '../downlink/downlink_protocol.dart';
import '../mutation/mutation_store.dart';
import '../uplink/uplink_protocol.dart';

/// The wire format, as one seam. Workers ask the codec for request bytes and
/// hand it response bytes; which encoding those bytes are in is the codec's
/// business alone, so no worker constructs or parses a wire representation.
abstract interface class LocalSyncProtocolCodec {
  Uint8List encodeUplinkRequest({
    required String clientId,
    required int batchSequence,
    required List<StoredMutationOperation> mutations,
    Map<int, StoredMutation> records = const {},
  });

  UplinkResponse decodeUplinkResponse(
    Uint8List bytes, {
    required Set<int> requestMutationIds,
  });

  Uint8List encodeDownlinkRequest({
    required String clientId,
    required String scope,
    required int afterSyncId,
  });

  DownlinkPage decodeDownlinkPage(Uint8List bytes);

  Uint8List encodeDownlinkSubscribe(Iterable<String> scopes);

  DownlinkLiveMessage decodeDownlinkLiveMessage(Uint8List bytes);
}
