# Parse

## 1. Introduction and Goals

Parse turns one or more `.model` files into structured declarations with token positions, so a schema author can be pointed at the offending place.

## 3. Context and Scope

- Input: the CLI concatenates every `*.model` file in the input directory in path order; the library takes one string.
- Output: JSON declarations for enums, models, mutations, unique constraints and prerequisites, consumed in the same call by [Validate](validate.md).
- Errors: `line:col: message (found 'token')`; the CLI rewrites the line into `path:line`.

## 5. Building Block View

- **Lexer.** Identifiers and digit runs, double-quoted strings with backslash escapes, the punctuation `{ } ( ) [ ] ? , . @ < > :`, and `//` line comments. Anything else is an error. Every token carries its line and column.
- **Grammar.** Four declarations: `enum`, `model`, `mutation`, `prerequisite`. Directives are `@@name(args)` at declaration level and `@name(args)` on fields or slots; arguments are positional or `key: value`, and values are identifiers, dotted paths, strings, lists or nested invocations.
- **CLI.** `ahead compile INPUT_DIR OUTPUT_DIR [--mutation-history FILE] [--initialize-mutation-history] [--schema-fence FILE] [--backend-runtime SPEC] [--client-runtime SPEC]`.

Code: `lex` and `Parser` in [compiler/lib.rs](../../../../crates/compiler/src/lib.rs); file handling in [compiler/main.rs](../../../../crates/compiler/src/main.rs).

## 10. Quality Requirements

- A syntax error names its line. Evidence: [compiler/tests/compiler.rs](../../../../crates/compiler/tests/compiler.rs) `rejects_unknown_with_location`.

## 11. Risks and Technical Debt

- **Accepted limitation (current structure):** parsing and validation are one function over shared JSON values; there is no typed syntax tree. The Parse/Validate split in the component tree is the target design.
- **Accepted limitation:** there are no numeric or boolean literals outside `@@version`; this is the parsing half of the missing field default ([#27](https://github.com/zanminwang/ahead/issues/27)).
