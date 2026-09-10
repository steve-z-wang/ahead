final class ModelSource {
  const ModelSource({required this.path, required this.contents});

  final String path;
  final String contents;
}

final class SourceLocation {
  const SourceLocation({
    required this.path,
    required this.offset,
    required this.line,
    required this.column,
  });

  final String path;
  final int offset;
  final int line;
  final int column;

  @override
  String toString() => '$path:$line:$column';
}

final class SourceSpan {
  const SourceSpan({required this.start, required this.end});

  final SourceLocation start;
  final SourceLocation end;
}

final class DefinitionException implements Exception {
  const DefinitionException({required this.location, required this.message});

  final SourceLocation location;
  final String message;

  @override
  String toString() => '$location: $message';
}
