# Parse

Convert schema text into structured definitions.

Current code: [compiler/lib.rs](../../../../crates/compiler/src/lib.rs) (`lex`, `Parser`, the declaration loop at the top of `compile`); file handling in [compiler/main.rs](../../../../crates/compiler/src/main.rs).

## 1. Introduction and Goals

- Turn one or more `.model` files into JSON declarations with enough position information to point a schema author at the offending token.

## 3. Context and Scope

- Input: the concatenation of every `*.model` file in the input directory, sorted by path, each followed by a newline (CLI); or a single string (`compile`).
- Output: in-memory JSON arrays for `models`, `enums`, `mutations`, `constraints` (`@@unique`) and `prerequisites`, handed straight to [Validate](validate.md) inside the same function.
- Errors: `line:col: message (found 'token')` strings; the CLI rewrites `line` to `path:line-in-file`.

## 5. Building Block View

- Lexer: whitespace-separated tokens of identifiers/numbers (`[A-Za-z0-9_]+`), double-quoted strings with backslash escapes, and the single characters `{ } ( ) [ ] ? , . @ < > :`; `//` starts a line comment; any other character is `unsupported character`. Every token carries `line` and `col`.
- Parser: `peek`/`take`/`eat`/`need`/`ident`; `expression` parses lists, strings, dotted names and invocations `Name(arg, key: value)`; `arguments` builds an object with positional keys `"0"`, `"1"`, … and named keys, refusing duplicates.
- Declarations: `enum Name { … }`, `model Name { … }`, `mutation Name { … }`, `prerequisite Name(field Type, …)`; anything else is `unsupported declaration`. Model bodies accept fields and `@@id`/`@@unique`; mutation bodies accept slots, `@@version(n)` and `@@sequence(...)`.
- There is no separate AST type: parsing produces `serde_json::Value`s that later passes mutate in place.

## 6. Runtime View

- CLI (`ahead compile INPUT_DIR OUTPUT_DIR [--mutation-history FILE] [--initialize-mutation-history] [--schema-fence FILE] [--backend-runtime SPEC] [--client-runtime SPEC]`): read and concatenate sources, compile, fence, reconcile history, then write outputs ([Generate](generate.md)).

## 10. Quality Requirements

- Positioned parse errors (S1): [compiler/tests/compiler.rs](../../../../crates/compiler/tests/compiler.rs) `rejects_unknown_with_location`.

## 11. Risks and Technical Debt

- **Confirmed gap versus the target: Parse and Validate are one function.** `compile` is a single 500-line function whose passes share mutable JSON; there is no typed AST for other tools to consume. Evidence: [compiler/lib.rs](../../../../crates/compiler/src/lib.rs). The component split in the overview is a documentation boundary, not a code boundary.
- **Confirmed limitation: no numeric or boolean literals.** The lexer tokenizes digits as identifiers and only `@@version` parses a number; this is the parsing half of the missing `@default` ([#27](https://github.com/zanminwang/ahead/issues/27)).
- Position quality for semantic errors is a [Validate](validate.md) finding.
