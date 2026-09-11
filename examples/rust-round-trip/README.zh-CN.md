# Rust 完整往返示例

[English](README.md) | [简体中文](README.zh-CN.md)

本示例包含嵌入式 Node 后端、使用 Prisma/PostgreSQL 的业务数据库、共享 Rust 协议 runtime、生成的 TypeScript/Dart Model，以及本地 SQLite 客户端。所需内容全部位于本仓库中，不依赖 Oasis checkout。

在 macOS 上，确保 PATH 中有 Node 22.18+（已用 26.4 验证）、Rust（由 `rust-toolchain.toml` 固定版本）、Python 3 和 PostgreSQL 命令行工具，然后运行：

```sh
bash examples/rust-round-trip/run.sh
```

脚本会构建 native runtime、生成 Model，并启动私有的一次性 PostgreSQL 集群和监听 `127.0.0.1:4242` 的 HTTP server。退出时只清理它自己创建的临时 PostgreSQL 集群。开发认证使用 `Bearer demo-user`。

在另一个终端中，从仓库根目录运行：

```sh
node examples/rust-round-trip/client.mts
```

先尝试 `sync`，再运行 `edit   hello   `，然后运行 `show`。本地乐观文本会保留空白。再次运行 `sync`：后端会去除文本首尾空白，客户端在对应 Pull Checkpoint 到达后替换乐观状态。执行 `edit reject` 再执行 `sync` 可演示拒绝与恢复。在同步前关闭并重新打开 CLI，可观察离线修改的持久化。客户端数据保存在 `example-client.sqlite`；可通过 `LFS_DATABASE` 选择其他路径。

- `models/entry.model`：源码 schema 与 Mutation 契约。
- `generated/`：生成的 schema、Mutation history 和各语言 facade。
- `server.mts`：应用自己管理的数据库操作和事务参与、Loader、Handler，以及显式 Channel 发布。HTTP 和 WebSocket 挂载到同一 server。
- `client.mts`：位于通用 Rust client 之上的生成式 TypeScript API。
- `integration/e2e/dart_client.dart`（仓库根目录下）：连接相同后端的真实 Dart 客户端。

要自动运行两种语言，请安装 Dart 并从根目录执行 `bash integration/e2e/run.sh`。测试使用自己创建的临时 server/database，验证响应丢失后的重试、规范化、拒绝、重启，以及网络响应延迟期间的编辑。
