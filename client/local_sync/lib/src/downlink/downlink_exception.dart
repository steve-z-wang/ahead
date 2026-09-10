final class DownlinkChangeException implements Exception {
  const DownlinkChangeException({
    required this.syncId,
    required this.model,
    required this.operation,
    required this.cause,
    required this.stackTrace,
  });

  final int syncId;
  final String? model;
  final String? operation;
  final Object cause;
  final StackTrace stackTrace;

  @override
  String toString() {
    final address = [
      if (model != null) model,
      if (operation != null) operation,
    ].join('.');
    return 'DownlinkChangeException(syncId: $syncId'
        '${address.isEmpty ? '' : ', change: $address'}, cause: $cause)';
  }
}

final class DownlinkPageException implements Exception {
  const DownlinkPageException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() =>
      'DownlinkPageException: $message'
      '${cause == null ? '' : ' ($cause)'}';
}
