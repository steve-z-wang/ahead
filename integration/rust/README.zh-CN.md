# Rust 集成测试

[English](README.md) | [简体中文](README.zh-CN.md)

`cargo test -p lfs-integration` 运行 64 种确定性组合，覆盖 ACK 丢失、本地编辑、Pull/ACK 顺序、拒绝与重启。预期可见值的断言独立于客户端 reducer；后端 Host fixture 提供受控持久化。真实 PostgreSQL 事务行为在 `integration/persistence` 下测试。

运行小规模容量诊断：

```sh
cargo run -p lfs-integration --example capacity --release
```

它对一条 Record 分别排队 10 次和 1,000 次更新，每次 Mutation 都进行一次真实 SQLite commit，然后应用一页权威数据，检查 pending replay 是否保留最新本地值。报告包含入队的 p50/p95，以及一次 page/replay 的耗时。退出时会移除临时数据库。

在开发用 macOS arm64 host 上（2026-09-10，优化构建），结果为：

| 待处理数量 | 入队 p50 | 入队 p95 | 一页数据 + 重放 |
| --- | --- | --- | --- |
| 10 | 0.42 ms | 0.67 ms | 0.59 ms |
| 1,000 | 2.17 ms | 3.51 ms | 5.38 ms |

这些是极小工作集下单次运行的本地诊断样本，不衡量大型多 Record 缓存、移动设备、网络延迟、bridge 开销或生产吞吐量。重放完全在 Rust 中执行；该测量不包含逐字段的跨语言回调。
