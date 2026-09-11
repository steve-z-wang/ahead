# 双语文档实施计划

[English](../../../superpowers/plans/2026-09-10-bilingual-documentation.md) | [简体中文](2026-09-10-bilingual-documentation.md)

> **供 agent 执行：** 使用 superpowers:subagent-driven-development 完成翻译任务并审查结果。

**目标：** 为现有全部 Markdown 文档提供英文和简体中文，并通过可审查的 PR 交付。

**架构：** 保留现有路径作为英文版。README 翻译以 `README.zh-CN.md` 与原文件并列；其他翻译在 `docs/zh-CN/` 下镜像原目录结构。每页链接到其另一语言版本。

**技术栈：** Markdown、Git 和本地 Python 验证脚本。

## 全局约束

- 完整翻译现有全部 24 份 Markdown 文档，包括历史计划和附带的启动图片 README。
- 保留技术含义、限制、历史状态、任务完成标记、API 标识符、wire 字段、命令和可执行示例。
- 英文保留在现有路径。添加并列的中文 README，以及 `docs/zh-CN/` 下的镜像中文文档。
- 每页必须链接到另一语言版本。中文页到已翻译文档的链接应保持中文；源码链接必须指向原始源码文件。
- 不修改 runtime、schema、依赖或协议。
- 记录双语维护约定，以及未来双语 wiki/文档站的要求。网站实现、框架选择和发布属于后续阶段。
- 向 `main` 开 PR；本任务不合并，也不发布网站。

## 任务 1：翻译架构与历史设计文档

**文件：** `docs/architecture/code-organization.md`、`docs/architecture/concepts-and-naming.md`、`docs/next-things.md`、`docs/superpowers/plans/2026-09-10-rust-rebuild.md`、`docs/superpowers/specs/2026-09-10-existing-logic-audit.md` 和 `docs/superpowers/specs/2026-09-10-rust-core-design.md` 的英文原路径与中文对应页。

1. 完整阅读六份原文。
2. 将解释文字整理为完整英文版和连贯中文版，不改变技术或历史陈述。
3. 保留可执行代码块；需要保持示例完全一致时，代码注释不变。
4. 添加语言对应链接，并调整中文页指向文档和源码的相对链接。
5. 检查完整性、术语、代码块、链接，并运行 `git diff --check`。

## 任务 2：翻译入口并完善文档导航

**文件：** 其余所有已跟踪 README、`docs/architecture/compatibility-and-recovery.md`、`docs/implementation-progress.md`、它们的中文对应页、本计划及中文版，以及 `docs/documentation.md` 和中文版。

1. 翻译所有剩余文档，保留示例和验证证据。
2. 添加相互对应的语言链接，以及从两个根 README 都能进入的双语维护指南。
3. 验证每份原文都有完整对应页，所有本地 Markdown 链接和标题锚点均可解析，并且两个版本的可执行代码块一致。
4. 审查完整 diff，检查语义偏移和意外的非文档改动。
5. Commit、push 文档分支，并开 PR 说明语言布局和检查结果。

## 验证

对两个版本运行 Markdown 覆盖、本地链接/锚点，以及代码块示例一致性检查，然后运行 `git diff --check`。手动审查架构术语与限制的翻译。本次只修改文档，无需运行 runtime 测试。
