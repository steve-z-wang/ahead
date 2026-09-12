# Documentation website implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development for the bounded site build task and independent final review.

**Goal:** Deliver a reviewable English documentation website PR, separate from the English source-documentation conversion.

**Architecture:** MkDocs Material renders existing Markdown through deterministic staging, with a small website-only homepage and concept guide. A standalone Python build environment and GitHub Actions validate it without compiling the framework.

**Tech stack:** Python, MkDocs Material, Markdown, CSS, GitHub Pages.

## Global constraints

- English only; no locale copies or language switcher.
- Preserve executable examples and accurate source-alpha/platform/transaction semantics.
- Reuse repository Markdown; keep generated staging and HTML untracked.
- Search, copy buttons, dark/light mode, keyboard navigation and responsive mobile layout must work.
- Site routes must work under `/otter-sync/` on GitHub Pages.
- Build on PRs; only an explicit main-branch workflow dispatch can deploy. Do not change repository settings or deploy during this task.
- Open the website PR against `codex/english-docs`, making its dependency on the English-docs PR explicit.

## Task 1: Documentation build and delivery

Files: `website/prepare.py`, `website/mkdocs.yml`, `website/requirements.txt`, `website/README.md`, `website/test_prepare.py`, `.github/workflows/docs.yml`, `.gitignore`.

- Implement deterministic staging from the agreed page map. Translate local document links into site links, map other valid source paths to GitHub, preserve code fences, and fail on missing selected source pages.
- Test mapping of relative links, fragments, source links, and unchanged fenced examples; build with `mkdocs build --strict`.
- Pin a working dependency environment and document exact setup, preview, build and manual Pages deployment commands.
- Add PR build/artifact checks and a manual deployment job restricted to main; no secrets or privileged PR execution.

## Task 2: Reader experience and verification

Files: `website/content/index.md`, `website/content/concepts.md`, `website/stylesheets/extra.css`, `website/assets/logo.svg`, root `README.md`, `docs/documentation.md`.

- Write the concise homepage and practical concept guide against the existing SDK and settlement behavior. Use the approved visual tokens and static local-first flow diagram.
- Link the website source/preview instructions from the repository README; explain the shared Markdown maintenance path.
- Run strict build and check rendered internal links/anchors under the project subpath.
- Inspect desktop and mobile screenshots; exercise navigation, search, theme switch and code-copy controls in a browser.
- Review the complete website-only diff; fix findings, commit, push and open the second PR without merging/deploying.
