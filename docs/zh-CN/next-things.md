# Next things / TODO

[English](../next-things.md) | [简体中文](next-things.md)

> 历史设计记录（2026-09-10）：下文的状态说明与拟议 API 反映原规划阶段。当前已交付范围与已验证的限制见[实现验证记录](implementation-progress.md)。

2026-09-10：用户明确决定先完成保留原行为的 Rust 重写，再讨论以下能力。这里的条目不是当前实现的前置条件，也不代表已经实现。

## 当前范围

从零实现 schema 驱动的 Rust client/server runtime、语言 SDK、生成器和 persistence adapter。算法行为以参考实现为准；命名和对外 API 的改善不能暗中改变事务、队列、结算或协议语义。

## 之后再做

- [ ] **跨 channel 的 record revision**：同一 record 从不同 channel 到达时比较内容版本；不将 channel cursor 作为跨 channel 的新旧标准。
- [ ] recordRevision 与 loaded state 的一致性读取；同次发布向多个 channel 分发同一版本。
- [ ] 同版本幂等、冲突诊断、旧页面迟到及 Move A→B→A 测试。
- [ ] 在扩展跨 channel 语义时明确 remove-from-channel 与真实 delete，设计 tombstone/watermark 保留和安全清理。
- [ ] 评估 optional revision 的升级/fencing 成本；目前不决定所有 record 必带或按需开启。
- [ ] 单独评审当前 pull 失败后 skip/推进 cursor 的行为；记录风险，重写时不顺手变成整页原子 apply。
- [ ] 如有需要，重新讨论 per-mutation receipt / 独立事务及消除 accepted-prefix 阻塞；当前保留 batch 事务、batch receipt 和 prefix 结算。
- [ ] 新 wire version、counter 十进制字符串、epoch/reset、自动 GC；这些属于另行设计的协议变化，不随 Rust 迁移默认启用。
- [ ] 扩展 schema compatibility fence 对 identity/type/nullability 等变化的检查；保留当前 fence 后独立设计。
- [ ] 外部用户事务提交后的 wake、额外 polling 和多进程通知策略；先验证当前通知边界。
- [ ] 改进 settlement witness coverage、权限撤销后的恢复，以及当前 channel-authorizer/host 策略；不能在未评审时删除旧行为。

## 已确认的 naming

采用 [概念与命名](architecture/concepts-and-naming.md) 的名称；命名本身已确定，不再是 TODO。当前文档与新 API 使用 Channel、Loader、Push/Pull、Cursor/Checkpoint，旧源码与 wire/storage 字段保留原名以供对照。

## 先前 record revision 方案，供后续评审

下面保留先前的技术草案，术语已更新为当前命名；示例动作名不是已启用的 wire 字段。其中“推荐”“第一版/alpha”等表达均指未来能力设计，不是当前 Rust 重写的决定。可选性、删除语义、授权和 GC 仍需确认。


### 两种数字，各管一件事

- `channelCursor`：某个 channel 的交付进度，也用于 settlement witness。
- `recordRevision`：同一个 `(model, identity)` 的内容新旧；不能比较不同 record 的 revision。

推荐所有同步 record 从创建起带 revision，避免后来发现重叠时升级老消息的复杂性。不需要系统全局变量，也不是每张 model table 一个 counter。

同一 publish 调用向 A/B fanout，共用同一 record revision；A/B 各自分配 channel cursor。重复调用同一 record 的 publish 需要事务内合并或显式 reuse publication token，不能误称两个不同调用天然只加一次。

revision 的比较域还包含账号/服务实例的 authority namespace；同一客户端会话内同 key/revision 必须得到相同完整权威内容。不同 viewer 的内容若不同，不能在切换账号时共用未隔离的缓存。对同一 viewer 的不同 channel 不支持同 key/revision 的不同字段视图；需要拆 model/identity。

只因 audience 变化而再发布允许 bump revision（内容可相同）；保证是同 revision 不得代表冲突权威内容，反向不要求相同内容必须同 revision。

### Wire 三种动作

- `upsert(identity, recordRevision, fullState)`：可见权威状态。
- `removeFromChannel(identity)`：当前 channel 不再提供它；按该 channel 的顺序改变 membership。
- `deleteRecord(identity, recordRevision)`：实体真实删除，覆盖所有旧版本；删除必须仍通知受影响的 channel。

`removeFromChannel` 与 `deleteRecord` 是协议级明确区分，不能依靠 null 猜测。channel claim 仍有存在价值，不因新增 record revision 就可删掉。

### Client 应用规则

1. 先验证 channel epoch/from/through 和 page 顺序。
2. membership 按 channel 流进度处理；record 内容按跨 channel recordRevision 判断。旧内容被忽略并不意味着其有效 membership 事件可以一并丢弃。
3. 新 upsert 推进 authoritative base，重放 pending；同 revision 同内容幂等；同 revision 冲突内容为协议错误并停止推进。
4. 新 tombstone 阻止旧 upsert 复活；更旧 tombstone 同样不能覆盖新内容。
5. remove 只释放当前 claim；另有有效 claim 则保留。最后 claim 离开时，authority availability 变 absent，并按既定 replay 规则处理 pending，不能把 pending silently 丢掉。
6. channel removal 导致父记录离开，不得不加判断就清除孩子其他 channel 的有效 claim。实体 cascade 与 channel-membership cascade 分开测试。

### 最新 fetch 不解决乱序

snapshot S1 读取 rev10 后网络延迟；S2 读取 rev11 先到。客户端仍必须拒绝后来抵达的 rev10。invalidation 的旧 revision 不能与 loader 读到的新内容拼接；snapshot 中 current revision 与 state 必须相符。

### 存储规模与 reset

客户端保留版本 watermark/tombstone，防止离线旧消息复活；alpha 不做 TTL 猜测 GC。提供行数/字节统计和显式账号级 reset。server 保留 compacted invalidations 和去重信息。达到规模门槛前，设计 channel generation + snapshot reset：先 fencing 旧 session，再重建 claims/cursors，不删除 pending/local-only 数据。只有可以证明旧消息不可再出现，才清理 watermark。此机制未完成前，不宣称缓存永久有界。

channel 允许订阅不代表记录一定可见。loader 是内容授权边界；若 identity 本身敏感，运输层也须过滤未知 identity 的撤回通知。可选 channel guard 是优化/元数据保护，不是强制 business primitive。权限变化必须发布 withdrawal 或触发明确 resnapshot。
