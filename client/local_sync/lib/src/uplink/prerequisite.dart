import 'dart:convert';

import '../schema/model_id.dart';
import 'uplink_protocol.dart';

enum PrerequisiteAttemptResult { ready, retry, failed }

typedef PrerequisiteHandler =
    Future<PrerequisiteAttemptResult> Function(Map<String, Object> arguments);

final class PrerequisiteHandlerRegistry {
  PrerequisiteHandlerRegistry(Map<String, PrerequisiteHandler> handlers)
    : _handlers = Map.unmodifiable(handlers);

  final Map<String, PrerequisiteHandler> _handlers;

  Future<PrerequisiteAttemptResult> dispatch(
    PrerequisiteInvocation invocation,
  ) async {
    final handler = _handlers[invocation.name];
    if (handler == null) {
      throw UplinkDataException('unknown prerequisite', invocation.name, null);
    }
    return handler(invocation.arguments);
  }
}

final class PrerequisiteInvocation {
  PrerequisiteInvocation({
    required this.name,
    required Map<String, Object> arguments,
  }) : arguments = Map.unmodifiable(arguments),
       identity = _identity(name, arguments);

  final String name;
  final Map<String, Object> arguments;
  final String identity;

  @override
  bool operator ==(Object other) =>
      other is PrerequisiteInvocation && other.identity == identity;

  @override
  int get hashCode => identity.hashCode;

  static String _identity(String name, Map<String, Object> arguments) {
    final names = arguments.keys.toList()..sort();
    return jsonEncode([
      name,
      [
        for (final argumentName in names)
          [argumentName, ..._typedValue(arguments[argumentName]!)],
      ],
    ]);
  }

  static List<Object> _typedValue(Object value) => switch (value) {
    UUID(:final uuid) => ['UUID', uuid],
    String value => ['String', value],
    bool value => ['Boolean', value],
    int value => ['Int', value],
    double value => ['Float', value],
    DateTime value => ['DateTime', value.toUtc().toIso8601String()],
    _ => throw ArgumentError.value(value, 'arguments'),
  };
}
