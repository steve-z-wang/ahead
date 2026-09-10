final class LocalSyncTerminalException implements Exception {
  const LocalSyncTerminalException(this.message, [this.cause]);
  final String message;
  final Object? cause;
  @override
  String toString() => 'LocalSyncTerminalException: $message';
}
