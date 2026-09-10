import 'dart:io';

import 'semantic/model_graph.dart';
import 'semantic/model_graph_builder.dart';
import 'syntax/parser.dart';
import 'syntax/source.dart';

ModelGraph compileModelSources(Map<String, String> sources) {
  final entries = sources.entries.toList()
    ..sort((left, right) => left.key.compareTo(right.key));
  final documents = [
    for (final entry in entries)
      parseModel(ModelSource(path: entry.key, contents: entry.value)),
  ];
  if (documents.every((document) => document.models.isEmpty)) {
    throw const CompilerException('no Model definitions found');
  }
  return buildModelGraph(documents);
}

Future<ModelGraph> compileModelDirectory(String path) async {
  final directory = Directory(path);
  if (!await directory.exists()) {
    throw CompilerException('missing Sync definition directory: $path');
  }

  final files = await directory
      .list(recursive: true, followLinks: false)
      .where((entity) => entity is File && entity.path.endsWith('.model'))
      .cast<File>()
      .toList();
  files.sort((left, right) => left.path.compareTo(right.path));
  if (files.isEmpty) {
    throw CompilerException('no .model definitions found in: $path');
  }

  final sources = <String, String>{};
  for (final file in files) {
    sources[file.path] = await file.readAsString();
  }
  return compileModelSources(sources);
}

final class CompilerException implements Exception {
  const CompilerException(this.message);

  final String message;

  @override
  String toString() => 'CompilerException: $message';
}
