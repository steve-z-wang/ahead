import 'dart:convert';

/// The wire fence.
///
/// Field names ARE the contract (spec §2), so the committed JSON contract is
/// wire state rather than a build artifact: a Model or a field that has once
/// been published may gain company but may never leave. A rename is a removal
/// and an addition at once, which is why it fails here — the removal half
/// would silently stop answering a client that still speaks the old name.
///
/// Additions pass. Everything a generation may do that a deployed client
/// cannot notice, it may do.
class ContractBreak {
  const ContractBreak(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What the committed contract promises that [generated] no longer keeps.
///
/// Empty means the generation is additive-only. Both arguments are the decoded
/// contract JSON; a committed file that does not exist yet has nothing to
/// promise, so the caller passes null and gets nothing back.
List<ContractBreak> findContractBreaks({
  required Object? committed,
  required Object? generated,
}) {
  if (committed == null) return const [];
  final before = _models(committed, 'committed');
  final after = _models(generated, 'generated');
  final breaks = <ContractBreak>[];

  for (final entry in before.entries) {
    final model = after[entry.key];
    if (model == null) {
      breaks.add(
        ContractBreak(
          'Model "${entry.key}" is in the committed contract and not in this '
          'generation. A published Model is never removed or renamed — a '
          'client that still names it would stop being answered. Add the new '
          'Model beside it instead.',
        ),
      );
      continue;
    }
    final beforeFields = _fields(entry.value);
    final afterFields = _fields(model);
    for (final field in beforeFields.keys) {
      if (afterFields.containsKey(field)) continue;
      breaks.add(
        ContractBreak(
          'Field "${entry.key}.$field" is in the committed contract and not '
          'in this generation. A published field is never removed or renamed '
          '— a client that still sends or reads it would break. Add the new '
          'field beside it and leave this one alone.',
        ),
      );
    }
  }
  return breaks;
}

/// Reads a contract from its committed text, or null when there is none yet.
Object? decodeContract(String? source) {
  if (source == null || source.trim().isEmpty) return null;
  return jsonDecode(source);
}

Map<String, Object?> _models(Object? contract, String label) {
  if (contract is! Map) {
    throw FormatException('the $label contract must be a JSON object');
  }
  final models = contract['models'];
  if (models is! List) {
    throw FormatException('the $label contract must carry a models list');
  }
  final byName = <String, Object?>{};
  for (final model in models) {
    if (model is! Map) {
      throw FormatException('the $label contract has a malformed Model');
    }
    final name = model['name'];
    if (name is! String) {
      throw FormatException('the $label contract has an unnamed Model');
    }
    byName[name] = model;
  }
  return byName;
}

Map<String, Object?> _fields(Object? model) {
  final fields = (model as Map)['fields'];
  if (fields is! List) return const {};
  final byName = <String, Object?>{};
  for (final field in fields) {
    if (field is Map && field['name'] is String) {
      byName[field['name']! as String] = field;
    }
  }
  return byName;
}
