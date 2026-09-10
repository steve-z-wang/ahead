import 'dart:io';

import 'compiler.dart';
import 'mutation_history.dart';
import 'contract_fence.dart';
import 'emit/backend/backend_contract_builder.dart';
import 'emit/contract/model_contract_emitter.dart';
import 'emit/dart/dart_emitter.dart';
import 'emit/typescript/backend_typescript_emitter.dart';
import 'output/generated_file.dart';
import 'output/generated_output.dart';

Future<void> runLocalSyncCompiler(List<String> arguments) async {
  const allowed = {
    '--definitions',
    '--mutation-history',
    '--initialize-mutation-history',
    '--dart-out',
    '--contract-out',
    '--typescript-backend-out',
    '--allow-breaking-contract',
  };
  final values = <String, String>{};
  for (var index = 0; index < arguments.length; index += 1) {
    final option = arguments[index];
    if (!allowed.contains(option)) {
      throw CompilerException('unknown compiler argument: $option');
    }
    if (option == '--initialize-mutation-history') {
      if (values.containsKey(option))
        throw CompilerException('duplicate $option argument');
      values[option] = 'true';
      continue;
    }
    if (index + 1 >= arguments.length ||
        arguments[index + 1].startsWith('--')) {
      throw CompilerException('missing value for $option');
    }
    final value = arguments[++index];
    if (values.containsKey(option)) {
      throw CompilerException('duplicate $option argument');
    }
    values[option] = value;
  }
  final definitions = values['--definitions'];
  final dartOutput = values['--dart-out'];
  final contractOutput = values['--contract-out'];
  final typescriptOutput = values['--typescript-backend-out'];
  final breakingContractIssue = values['--allow-breaking-contract'];
  if (breakingContractIssue != null &&
      !RegExp(r'^CAP-[1-9][0-9]*$').hasMatch(breakingContractIssue)) {
    throw const CompilerException(
      '--allow-breaking-contract must name a CAP issue such as CAP-567',
    );
  }
  // Each consumer generates only its own output (CAP-423): Mobile asks for
  // --dart-out, the Backend for --contract-out + --typescript-backend-out.
  // Staleness across consumers is CI's job (regenerate + diff per side),
  // not this invocation's.
  if (definitions == null ||
      (dartOutput == null &&
          contractOutput == null &&
          typescriptOutput == null)) {
    throw const CompilerException(
      'usage: local_sync_compiler --definitions <directory> '
      '[--dart-out <directory>] [--contract-out <file>] '
      '[--typescript-backend-out <directory>] '
      '[--allow-breaking-contract <CAP-N>] '
      '— at least one output',
    );
  }
  final graph = await compileModelDirectory(definitions);
  final historyPath = values['--mutation-history'];
  final initialize = values.containsKey('--initialize-mutation-history');
  if (initialize && historyPath == null)
    throw const CompilerException(
      '--initialize-mutation-history requires --mutation-history',
    );
  MutationHistory history;
  if (historyPath != null) {
    final file = File(historyPath);
    if (await file.exists()) {
      if (initialize)
        throw const CompilerException(
          'mutation history already exists; initialization refused',
        );
      history = MutationHistory.decode(
        await file.readAsString(),
      ).reconcile(graph);
    } else {
      if (!initialize)
        throw CompilerException(
          'missing mutation history: $historyPath; restore committed history or initialize explicitly',
        );
      if (graph.mutations.any((mutation) => mutation.version != 1))
        throw const CompilerException(
          'initial mutation history must begin at v1',
        );
      history = MutationHistory.capture(graph);
    }
  } else {
    if (graph.mutations.any((mutation) => mutation.version != 1))
      throw const CompilerException(
        'versioned mutations require --mutation-history',
      );
    history = MutationHistory.capture(graph);
  }
  final dartSources = dartOutput == null
      ? null
      : GeneratedOutput.prepare(emitDart(graph, history: history));
  String? contract;
  if (contractOutput != null) {
    contract = emitModelContract(graph);

    // The committed contract is wire state, not a build artifact: a published
    // Model or field may gain company but may never leave. Checked before
    // anything is written, so a refused generation leaves the tree as it was.
    final contractFile = File(contractOutput);
    final breaks = findContractBreaks(
      committed: decodeContract(
        await contractFile.exists() ? await contractFile.readAsString() : null,
      ),
      generated: decodeContract(contract),
    );
    if (breaks.isNotEmpty && breakingContractIssue == null) {
      throw CompilerException(
        'the wire contract may only grow:\n'
        '${breaks.map((issue) => '  - $issue').join('\n')}',
      );
    }
    if (breaks.isNotEmpty) {
      stderr.writeln(
        'LocalSync contract break explicitly authorized by '
        '$breakingContractIssue:\n'
        '${breaks.map((issue) => '  - $issue').join('\n')}',
      );
    }
  }
  BackendTypescriptEmission? typescript;
  if (typescriptOutput != null) {
    typescript = emitBackendTypescript(
      buildBackendContract(graph),
      history: history,
    );
    GeneratedOutput.prepare(typescript.files);
  }

  if (historyPath != null)
    await GeneratedFile.replace(historyPath, history.encode());
  if (dartOutput != null && dartSources != null) {
    await GeneratedOutput.replace(dartOutput, dartSources);
  }
  if (contractOutput != null && contract != null) {
    await GeneratedFile.replace(contractOutput, contract);
  }
  if (typescript != null && typescriptOutput != null) {
    await GeneratedOutput.replace(typescriptOutput, typescript.files);
  }
}
