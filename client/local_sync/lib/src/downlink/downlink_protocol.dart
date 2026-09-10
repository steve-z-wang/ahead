final class DownlinkDataException implements FormatException {
  const DownlinkDataException(this.message, [this.source, this.offset]);

  @override
  final String message;
  @override
  final Object? source;
  @override
  final int? offset;

  @override
  String toString() => 'DownlinkDataException: $message';
}

enum DownlinkOperation { upsert, delete }

final class AddressedModelChange {
  AddressedModelChange({
    required this.syncId,
    required Map<String, Object?> raw,
  }) : raw = Map.unmodifiable(raw);

  final int syncId;
  final Map<String, Object?> raw;
}

final class DownlinkPage {
  DownlinkPage({
    required this.scope,
    required this.fromSyncId,
    required this.throughSyncId,
    required List<AddressedModelChange> changes,
  }) : changes = List.unmodifiable(changes);

  final String scope;
  final int fromSyncId;
  final int throughSyncId;
  final List<AddressedModelChange> changes;
}

sealed class DownlinkLiveMessage {
  const DownlinkLiveMessage();
}

final class DownlinkSubscribed extends DownlinkLiveMessage {
  DownlinkSubscribed({
    required Iterable<String> scopes,
    required Iterable<DownlinkScopeRejection> rejections,
  }) : scopes = _canonicalScopes(scopes),
       rejections = _canonicalRejections(rejections);

  final List<String> scopes;
  final List<DownlinkScopeRejection> rejections;
}

final class DownlinkScopeRejection {
  const DownlinkScopeRejection({required this.scope, required this.code});

  final String scope;
  final String code;
}

final class DownlinkLivePage extends DownlinkLiveMessage {
  const DownlinkLivePage(this.page);

  final DownlinkPage page;
}

List<String> _canonicalScopes(Iterable<String> scopes) {
  final values = scopes.toList(growable: false);
  if (values.toSet().length != values.length) {
    throw const FormatException('acknowledged scopes must be unique');
  }
  final sorted = values.toList()..sort();
  return List.unmodifiable(sorted);
}

List<DownlinkScopeRejection> _canonicalRejections(
  Iterable<DownlinkScopeRejection> rejections,
) {
  final values = rejections.toList(growable: false);
  final seen = <String>{};
  for (final rejection in values) {
    if (!seen.add(rejection.scope)) {
      throw const FormatException('rejected scopes must be unique');
    }
    if (rejection.code.isEmpty) {
      throw const FormatException('scope rejection code must not be empty');
    }
  }
  final sorted = values.toList()
    ..sort((left, right) => left.scope.compareTo(right.scope));
  return List.unmodifiable(sorted);
}
