# Documentation languages and maintenance

[English](documentation.md) | [简体中文](zh-CN/documentation.md)

The documentation is maintained in English and Simplified Chinese. English is the primary edition for shared terminology and technical changes; both editions describe the same behavior, examples and limitations.

## File layout

| Document | English | Simplified Chinese |
| --- | --- | --- |
| Repository entry point | `README.md` | `README.zh-CN.md` |
| Package, example or test guide | `<directory>/README.md` | `<directory>/README.zh-CN.md` |
| Architecture, evidence or roadmap | `docs/<path>.md` | `docs/zh-CN/<path>.md` |

Existing English URLs and repository paths remain stable. Every page has a language switch near the top linking to its exact counterpart. Translated pages link to the translated versions of other documents; links to code and external references still point to the original resources.

## Editing both editions

1. Update the English page and its Chinese counterpart in the same PR, keeping sections, examples, constraints and status statements equivalent.
2. Keep API identifiers, protocol fields, commands and executable examples unchanged across languages. Translate explanation and prose diagrams; source code comments may remain in the original language to preserve shared samples.
3. Use the accepted [concept names](architecture/concepts-and-naming.md): Model, Record, Identity, Mutation, Handler, Loader, Channel, Publish, Client, Persistence, Push/Pull, Cursor and Checkpoint. Translate the explanation, not the identifier.
4. When adding or renaming a page, add or rename its counterpart and update incoming links in both editions. Check relative paths from the translated page's actual directory, including heading fragments.
5. Review translation completeness, example parity, local links and Markdown formatting. A translation must not silently introduce a new feature or strengthen a platform-support claim.

Historical design documents and implementation plans retain the status and proposed APIs recorded at the time. For current implemented behavior and verified support, begin with the [root README](../README.md), [package documentation](../README.md#packages) and [implementation evidence](implementation-progress.md).

## Next stage: bilingual wiki / documentation site

The future developer documentation site must support English and Simplified Chinese, with a language switch that preserves the current page when a counterpart exists. Both editions should have equivalent navigation and examples.

Use repository Markdown as the maintained source, adapting its layout to the selected site framework when needed. Avoid a second independently maintained copy in GitHub Wiki. If a GitHub Wiki is also used, prefer links to the canonical pages or generated content.

Choosing the site framework, designing the site, deciding untranslated-page behavior and configuring hosting are the next stage. This documentation PR does not implement or publish a site; repository visibility and any public documentation deployment require a separate decision.
