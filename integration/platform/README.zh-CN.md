# 平台验证

[English](README.md) | [简体中文](README.zh-CN.md)

完整 host 检查会验证 macOS arm64 上的 Node 和 Dart。Simulator 检查单独执行，因为它需要 Xcode 和已安装且可用的 iOS runtime。

```sh
bash integration/platform/run_ios_simulator_smoke.sh
```

当前测试工具面向已安装的 iOS 18.x runtime 和 iPhone 16 simulator。它将 `lfs-dart` 构建为 arm64 simulator 静态库，将 native symbols 强制链接到 Flutter app，并创建一次性 simulator。Dart 使用 `DynamicLibrary.process()`，不提供显式 library path。测试检查直接写入、排队的 Mutation、冻结字节、关闭/重新打开，以及完整的应用终止/重新启动。每个 SDK 步骤都有时间限制并写入阶段标记。脚本只删除自己创建的 simulator。

## 2026-09-10 的观察结果

- Rust `aarch64-apple-ios-sim` 静态库构建通过。
- Flutter analysis 和 simulator app 构建通过。
- 链接后的 debug library 导出了 `lfs_call` 和 `lfs_free`。
- 实际 iOS FFI/SQLite/重启验证**未通过**。新的 iOS 18.5 simulator 已启动，app 已安装，但在限定等待时间内，启动没有产生任何 console 输出，也没有出现第一个 Dart `main()` 阶段标记。观察到的失败位于 CoreSimulator 启动和 Dart 入口之间；它既不能证明 native SDK 有缺陷，也不能证明 FFI 加载成功。
- 另一个一次性 iOS 26.5 simulator 在首次启动迁移时停滞。不声称 iOS 26.5 runtime 已成功运行。
- 所有一次性 simulator 均已移除。用户原有 simulator 未作改动。
- 本机没有 Android SDK/emulator，也无法验证实体设备。不能仅凭 Rust 源码就声称支持 Android。

[代码提交 92bf410 的 macOS/Linux CI 运行](https://github.com/steve-z-wang/local-first-state/actions/runs/34555679980) 在两个全新 runner 上通过了完整 host 检查、真实 Node/Dart/PostgreSQL HTTP 端到端测试、优化构建和 native binding smoke。该结果不能延伸到 iOS 或 Android。详细覆盖范围见[实现记录](../../docs/zh-CN/implementation-progress.md)。
