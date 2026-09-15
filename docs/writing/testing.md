# Writing testing documentation

## Style

Explain the expected behavior in plain language. Use prose for reasoning, tables for comparisons and lists for independent items. Keep only the detail needed to choose, understand or reproduce a test.

## Sections

A testing topic should explain its responsibility and scope, link to the owning architecture or guarantee, and identify existing tests. Include runnable commands, prerequisites and expected results when applicable. Add failure reproduction instructions where seeds, fixtures or external services matter.

The testing overview contains a responsibility tree and a separate code map. Distinguish test scope from method or environment: simulation can exercise multiple components together. Category READMEs link to their topics; explain collaboration at a parent level when the children alone do not make it clear.

## Notes

### Requirements and evidence

Guarantees describe overall Rust sync behavior. Component rules stay with their architecture owners. Test documentation explains how those requirements are checked; it must distinguish existing assertions, proposed tests, known defects and undecided behavior.

### Coverage claims

Inspect assertions rather than relying on test names. State the conditions and limitations of the evidence: a close/reopen is not a process crash, a model database is not PostgreSQL, and a generated sequence checks only its implemented invariants. Report a command as passing only after running it.

### Follow-up work

Keep a reproducible failure and the affected behavior with the owning component. Use the coverage review for gaps spanning components. A documentation-only change may define intended testing without implementing it; name that boundary and leave execution results pending.
