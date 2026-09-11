# iOS SDK smoke app

[English](README.md) | [简体中文](README.zh-CN.md)

这个内部 Flutter 测试应用使用链接到进程中的 Rust 和 SQLite，验证 local-first-state Dart facade。按 [platform README](../README.zh-CN.md) 的说明，从仓库根目录运行 `bash integration/platform/run_ios_simulator_smoke.sh`。

第一次启动会写入一条本地记录、排队一次乐观编辑、冻结请求，并验证关闭/重新打开。第二次启动应用时，会比较持久化的记录以及完全一致的冻结请求。阶段/结果文件写入应用的临时目录；每个 SDK 步骤都有超时。临时存储足以支持这个受控的重启测试，但应用应使用 application-support 数据库路径持久保存用户数据。

这是测试工具，不是公开示例，也不代表已验证 iOS runtime 支持。当前结果与限制记录在上一级 README 中。
