# Bilingual documentation implementation plan

[English](2026-09-10-bilingual-documentation.md) | [简体中文](../../zh-CN/superpowers/plans/2026-09-10-bilingual-documentation.md)

> **For agentic workers:** Use superpowers:subagent-driven-development to execute the translation task and review its result.

**Goal:** Make every existing Markdown document available in English and Simplified Chinese, delivered in a reviewable PR.

**Architecture:** Preserve existing paths as the English edition. README translations live beside their originals as `README.zh-CN.md`; other translations mirror the existing directory structure under `docs/zh-CN/`. Each page links to its counterpart.

**Tech Stack:** Markdown, Git, and a local Python verification script.

## Global constraints

- Translate the complete content of all 24 existing Markdown documents, including historical plans and the bundled launch-image README.
- Preserve technical meaning, limitations, historical status, task completion markers, API identifiers, wire fields, commands, and executable examples.
- Keep English at existing paths. Add sibling Chinese READMEs and mirrored Chinese documentation under `docs/zh-CN/`.
- Each page must link to its language counterpart. Chinese links to translated documents should stay in Chinese; source-file links must resolve to the original source files.
- Make no runtime, schema, dependency, or protocol changes.
- Document the bilingual maintenance convention and the requirement for a future bilingual wiki/documentation site. Site implementation, framework selection, and publishing are a later stage.
- Open a PR against `main`; do not merge or publish a site in this task.

## Task 1: Translate architecture and historical design documents

**Files:** English originals and Chinese counterparts for `docs/architecture/code-organization.md`, `docs/architecture/concepts-and-naming.md`, `docs/next-things.md`, `docs/superpowers/plans/2026-09-10-rust-rebuild.md`, `docs/superpowers/specs/2026-09-10-existing-logic-audit.md`, and `docs/superpowers/specs/2026-09-10-rust-core-design.md`.

1. Read all six originals in full.
2. Translate their prose into complete English editions and coherent Chinese editions without changing technical or historical claims.
3. Preserve executable code blocks; keep code comments unchanged when needed to retain exact sample parity.
4. Add counterpart links and adjust translated relative links to documentation and source files.
5. Review completeness, terminology, code fences, links, and `git diff --check`.

## Task 2: Translate entry points and complete documentation navigation

**Files:** All remaining tracked READMEs, `docs/architecture/compatibility-and-recovery.md`, `docs/implementation-progress.md`, their Chinese counterparts, this plan and its Chinese counterpart, and `docs/documentation.md` with its Chinese counterpart.

1. Translate all remaining documents, preserving examples and verification evidence.
2. Add reciprocal language links and a bilingual maintenance guide linked from both root READMEs.
3. Verify that every original has a full counterpart, all local Markdown links and heading fragments resolve, and executable fenced examples match across editions.
4. Review the complete diff for semantic drift and unintended non-documentation changes.
5. Commit, push the documentation branch, and open a PR describing the language layout and checks.

## Validation

Run Markdown coverage, local-link/fragment, and fenced-example parity checks across both editions, then `git diff --check`. Review translated architecture terms and limitations manually. Runtime tests are unnecessary because this change only edits documentation.
