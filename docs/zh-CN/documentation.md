# 文档语言与维护约定

[English](../documentation.md) | [简体中文](documentation.md)

文档提供英文和简体中文。英文是统一术语与技术变更的主要版本；两个版本描述相同的行为、示例和限制。

## 文件布局

| 文档 | 英文 | 简体中文 |
| --- | --- | --- |
| 仓库入口 | `README.md` | `README.zh-CN.md` |
| Package、示例或测试说明 | `<directory>/README.md` | `<directory>/README.zh-CN.md` |
| 架构、验证记录或路线图 | `docs/<path>.md` | `docs/zh-CN/<path>.md` |

已有英文 URL 和仓库路径保持稳定。每页顶部附近都有语言切换链接，指向对应页面。中文页面链接到其他文档的中文版本；源码和外部参考仍指向原始资源。

## 同时维护两个版本

1. 在同一个 PR 中更新英文页和中文对应页，保持章节、示例、约束及状态描述一致。
2. API 标识符、协议字段、命令和可执行示例在两个语言版本中保持不变。翻译解释文字和文字图示；为保持示例一致，源码注释可以保留原语言。
3. 使用已确认的[概念名称](architecture/concepts-and-naming.md)：Model、Record、Identity、Mutation、Handler、Loader、Channel、Publish、Client、Persistence、Push/Pull、Cursor 和 Checkpoint。翻译解释，不翻译标识符。
4. 新增或重命名页面时，同步新增或重命名对应页，并更新两个版本中的入链。按中文页面实际所在目录检查相对路径，包括标题锚点。
5. 检查翻译完整性、示例一致性、本地链接和 Markdown 格式。翻译不能悄悄引入新功能，也不能扩大平台支持的承诺。

历史设计文档和实施计划保留当时记录的状态及拟议 API。查看当前已实现行为和已验证支持情况时，请从[根 README](../../README.zh-CN.md)、[package 文档](../../README.zh-CN.md#packages)和[实现验证记录](implementation-progress.md)开始。

## 下一阶段：双语 wiki / 文档站

未来的开发者文档站必须支持英文和简体中文，并在存在对应页时，让语言切换保留当前页面。两个版本应有对应的导航和示例。

以仓库 Markdown 作为持续维护的来源，选定文档站框架后再按需要适配布局。避免在 GitHub Wiki 中独立维护第二份副本。如果同时使用 GitHub Wiki，优先链接到正式页面或使用生成内容。

选择文档站框架、设计网站、决定未翻译页面的处理方式，以及配置托管属于下一阶段。本次文档 PR 不实现或发布网站；仓库可见性以及任何公开文档部署需要另行决定。
