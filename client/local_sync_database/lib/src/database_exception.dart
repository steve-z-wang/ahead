enum DatabaseErrorKind {
  constraint,
  busy,
  corrupt,
  closed,
  invalidArgument,
  unknown,
}

final class DatabaseException implements Exception {
  const DatabaseException({
    required this.kind,
    required this.message,
    this.nativeCode,
    this.cause,
  });

  final DatabaseErrorKind kind;
  final String message;
  final int? nativeCode;
  final Object? cause;

  @override
  String toString() => 'DatabaseException($kind): $message';
}
