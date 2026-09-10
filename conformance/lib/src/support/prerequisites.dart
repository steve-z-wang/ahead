import 'dart:async';

import 'package:local_sync/local_sync.dart';

import '../generated/local_sync.dart';

LocalSyncPrerequisiteHandlers readyPrerequisites() =>
    LocalSyncPrerequisiteHandlers(
      remoteLabel: ({required key}) async => PrerequisiteAttemptResult.ready,
    );

final class ControlledPrerequisites {
  final _completed = <String, PrerequisiteAttemptResult>{};
  final _waiting = <String, Completer<PrerequisiteAttemptResult>>{};
  final calls = <String>[];

  late final handlers = LocalSyncPrerequisiteHandlers(
    remoteLabel: ({required key}) {
      calls.add(key);
      final completed = _completed[key];
      if (completed != null) return Future.value(completed);
      return (_waiting[key] ??= Completer<PrerequisiteAttemptResult>()).future;
    },
  );

  void complete(String key, PrerequisiteAttemptResult result) {
    _completed[key] = result;
    final waiting = _waiting.remove(key);
    if (waiting != null && !waiting.isCompleted) waiting.complete(result);
  }
}
