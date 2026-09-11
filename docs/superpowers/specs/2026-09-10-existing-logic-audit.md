# local-first-state：现有逻辑审查与覆盖表

日期：2026-09-10。状态：源码审查，未执行完整测试；这是设计输入，不是现有实现的正确性认证。

独立仓库参考提交：`989c4c769b1d41b4b3276f8c97f6bd8ef9eb4fb8`。原 Oasis 导出来源：`78e64a9bc93d3dab4bf256eed0a3051702f58882`。

下列仓库内路径相对于 local-first-state 根目录；Oasis 路径另行标识。新代码从零实现，现有源码作为行为参考保留。

> 范围更新：本轮只迁移现有行为。表中原先提出的改进、revision、epoch 和 failure-policy 变化均属 [Next things](../../next-things.md)，不是迁移任务；源码发现与风险继续保留。

> 命名对照：本审查保留旧源码的术语与路径。新实现采用 Scope → Channel、Materializer → Loader、Uplink/Downlink → Push/Pull；Sync ID 按用途区分 Cursor/Checkpoint。见 [概念与命名](../../architecture/concepts-and-naming.md)。此处旧路径指参考提交，不指当前 worktree 中已有代码。

## 1. 真实的数据路径

1. 生成的 Dart API 构造具名 mutation，包含按 schema 顺序排列的 create/update/delete。
2. 外层 SQLite transaction 可以包含直接本地写入和多个具名 mutation；后者有独立 savepoint/fate。
3. 第一次 optimistic 修改保存 authoritative before-image；main 表立即写入可见结果，同时持久化 mutation、操作、依赖和 scope 修改。UI 查询 main 表。
4. scheduler 根据 readiness、生命周期依赖和业务顺序依赖选任务；冻结 batch 后，未知结果必须重发相同请求。
5. 后端校验 owner、client、batch sequence、hash 和 mutation version；claim/receipt 在数据库事务中执行。
6. 当前整个 batch 共用一个 transaction，各 mutation 在 savepoint 内执行 resolver。业务拒绝只撤销当前 mutation；未知异常撤销整个 batch。
7. resolver 显式 invalidate scopes。每个 scope 独立 head；锁行、递增、更新 compacted invalidation。
8. ACK 持久化 rejection 和 required scope checkpoints。accepted 不等于可以撤下 optimistic 操作。
9. downlink 在读取时 materialize 当前完整内容。客户端更新 authoritative base，再 replay pending 操作。
10. required checkpoints 全部实际应用后才结算；ACK 晚于 downlink 时可从 durable cursor 判断，不必再等一页。

before-image 不是永远不变的初始快照；dirty 期间，它是持续被 downlink 更新的权威基础状态。纯本地 companion 的接受也可推进其本地基础状态。

## 2. 逐项覆盖

| 能力 | 当前入口 | Rust 重写去向 / 决策 |
|---|---|---|
| `.model` parser / diagnostics | `compiler/lib/src/syntax/`、`semantic/` | 先复用 build-time compiler 描述，后迁 Rust compiler；不先发明新 DSL |
| scalar、enum、list、nullable、UUID、DateTime | `semantic/model_graph.dart`、`server/src/model-contract/value-codec.ts` | Rust schema/protocol；SDK 只转换语言值 |
| 单/复合 identity、canonical key | `schema/model_id.dart`、`backend/identity-normalizer.ts` | Rust 统一；不用分隔符拼接复合 key |
| relation、inverse、unique、cascade graph | `semantic/model_graph_builder.dart`、`schema/relation_index.dart` | Rust 元数据/验证；生成 typed 关系 API |
| slot 顺序、optional/list slot、patch 白名单 | `mutation/model_operation.dart`、`backend/slot-binding-precheck.ts` | 先保留结构化契约，再改善业务输入 API |
| slot relation binding | `mutation/slot_binding_verifier.dart` | Rust；依赖 stored row 的验证在事务内 |
| mutation 历史版本 | `compiler/lib/src/mutation_history.dart` | 保留历史输入形状；不按新 schema 重解释已持久化请求 |
| schema compatibility fence | `compiler/lib/src/contract_fence.dart` | 保留旧 fence 的字段/model 消失检查；更广的类型、identity、nullability 检查延后 |
| 生成代码不承载算法 | `compiler/lib/src/emit/`、`tool/gate.sh` | 保留；生成层只输出类型、描述、转发 |
| main + sparse before-image | `storage/before_image_store.dart`、`row_rebuilder.dart` | Rust client；clean row 不保留 before-image |
| optimistic reducer | `projection/mutation_reducer.dart` | Rust；保留 absent/null 区别，明确冲突降级 |
| 外层 local transaction / mutation savepoint | `mutation/transaction_executor.dart`、`mutation_scope_executor.dart` | Rust transaction session；多次读取/写入可顺序交互 |
| 本地直接写入 | `storage/direct_model_writer.dart` | 保留，与 server fate 分开 |
| 本地 companion | `mutation/companion_model_writer.dart` | 保留：同 mutation fate，不上传；不能把 wire optimism 当权威内容 |
| cascade 扫描 main + before | `storage/cascade_expansion.dart`、`api/cascade_deleter.dart` | 迁移既有 cascade；进一步区分 scope removal 与真实删除的方案延后 |
| 顺序依赖 / 生命周期依赖 | `mutation/mutation_dependency_writer.dart` | Rust；不同拒绝传播和可同 batch 行为不能混为一谈 |
| readiness ledger | `uplink/readiness_ledger.dart` | Rust durable 状态；无行=pending；引用归零清理 |
| 媒体上传前置任务 | `uplink/prerequisite_runner.dart` | Rust 决策，宿主执行上传；ready/failed/retry 区分 |
| 调度与独立任务超车 | `uplink/mutation_scheduler.dart` | Rust；不能悄悄退化成全局 FIFO |
| frozen batch / 不确定结果重试 | `uplink/mutation_queue.dart`、`batch_executor.dart` | 保留 frozen batch 与 batch receipt |
| refusal、依赖传播、drop | `uplink/mutation_queue.dart` | Rust；已发未知结果不能当作取消成功 |
| 持久化拒绝收件箱 | `storage/mutation_rejection_store.dart`、`api/local_sync_mutations.dart` | 保留 code、操作快照、显式 acknowledge |
| identity 上传状态 | `uplink/uplink_status.dart` | Rust 派生，不另存易漂移状态 |
| 动态 scope 订阅 | `downlink/scope_store.dart`、`scope_reconciler.dart` | Rust durable desired state，启动/重连恢复 |
| optimistic scope 修改 | `downlink/transaction_scopes.dart` | 与所属 mutation 同 fate |
| HTTP pull / WS live 统一应用 | `downlink/downlink_worker.dart`、`downlink_page_queue.dart` | Rust 协议状态机；平台只运输 bytes/events |
| cursor/stale page | `downlink/downlink_page_processor.dart` | 保留现有行为；失败策略与 epoch 改进延后 |
| 多 scope settlement | `uplink_batch_checkpoints`、`_readBatchesReadyAfterAdvance` | 保留 barrier；不同 scope 数字不能互相比较 |
| accepted prefix | `downlink/downlink_page_processor.dart` | 保留 accepted-prefix 规则；独立结算延后 |
| scope row claims | `downlink/scope_row_ledger.dart` | 保留 membership 信息；不替代 freshness |
| 跨 scope record freshness | 当前无独立 record revision 仲裁 | Next things；本轮不加入 |
| tombstone / remove-from-scope | 当前 `state:null` 混用 | 本轮保留 null 语义；分开删除类型延后 |
| server idempotency/owner fencing | `backend/uplink-executor.ts`、`uplink-receipt.ts` | Rust server + atomic persistence |
| 显式 publish scopes | `backend/scope-ledger.ts` | 保留，不变成 ambient/model 自动路由 |
| 前后端数据模型解耦 | `backend/model-binding.ts` | 保留，一个业务表可投影多个客户端 model |
| materializer alignment | `backend/downlink-materializer.ts` | 保留现有 identity 对齐及可见性；新 Loader 接口须适配旧语义 |
| preparation 写入 | `prepareForViewer` | 迁移前保留事务要求；不能假设现有 loader 全是纯读 |
| scope authorizer | `backend/backend-options.ts` | 保留现有 authorizer 行为；是否改为可选延后讨论 |
| transaction adapter | `backend/transactions.ts`、`storage.ts` | 用户拥有事务；官方 adapter 提供原子能力 |
| commit wakeup | `backend/committed-changes.ts`、`downlink-subscription.ts` | 保留现有通知/catch-up；新增 polling 等恢复策略延后 |
| host/server | `backend/local-sync-host.ts` | 嵌入用户 server；独立 listener 仅示例便利功能 |
| token/auth/lifecycle/cancel | `transport/` | 宿主凭证与 I/O；Rust 决策；旧 session 回调不能污染新 session |
| query/get/watch/relations | `api/model_query.dart`、`projection/query_evaluator.dart` | Rust query IR/执行；SDK typed facade；commit 后通知 |
| read-only SQL | `api/read_only_sql.dart` | 保留 escape hatch，真实只读验证而不是字符串前缀 |
| database/savepoint/errors/watch | `client/local_sync_database*` | native 默认 Rust SQLite，扩展 adapter 同样跑契约 |
| 五组 conformance | `conformance/*/README.md` | Rust 算法测试 + ABI + DB 契约 + E2E；减少重复实现，不删协议验证 |
| build/CI/release | `tool/gate.sh`、`.github/workflows/test.yml` | 新旧 gate 分开；旧 Nest/Prisma 禁用 fence 不套在新 adapter 上 |

## 3. 不能照搬的行为

### Downlink 失败后仍推进 cursor

`downlink_page_processor.dart` 在 decode 或 `_CanonicalChangeFailure` 后调用 `_commitSkip`，后者执行 `_settleAndAdvance`。所以 cursor 到达并不总能证明权威变更成功落地。整页原子 apply / 失败不推进 cursor 是待独立评审的修复提议，已延后；重写先刻画并保留原行为，不将保留视为正确性认证。

### Snapshot 隔离要求不显式

`downlink-materializer.ts` 用 `transactions.write` 包住 head/scan/prepare/read；generic write 的接口本身没有说明 repeatable-read 保证。迁移时需刻画 head、invalidation、materialized state 的实际读取保证；增强 snapshot 与 record revision 的方案在 Next things。跨外部 API/数据库读取不声称自动原子。

### 用户外部事务可能没有 live wake

Oasis `backend/src/local-sync/prisma-persistence.ts` 的 touched scopes 用 wrapper-owned WeakMap 记录。注释明确：自行开的外部事务可以存 invalidation，却未必产生 live wake。用户 commit 后提示、polling 补偿漏发与跨实例通知的扩展在 Next things；本轮先验证并记录原行为。

### 整数上限不一致

scope counter 内部是 signed int64，wire JSON 和客户端受 JS safe integer 限制。新协议建议统一非负 signed-64 范围、十进制字符串 wire；SDK 不转 JS number。作为新 wire version，不偷偷兼容。

### Membership 与 authority 混合

`downlink_change_applier.dart` 的 upsert 没有跨 scope record revision 仲裁；null 只 release 当前 scope，其他 claim 存在就保留。它能表达离开一个 scope，却不能完整表达全局删除和跨 scope 旧内容迟到。

## 4. 实际产品需求检验

| Oasis 场景 | 结论 |
|---|---|
| 多人共享 Book | shared scope 合理，减少按人重复 invalidation；每个客户端仍需网络交付 |
| Move Moment 保留 identity，old/new Book 同时发布 | 必须测试交错到达、旧页迟到、子记录重归属；单 scope 设计不能自动解决 Move |
| Reply 保留发送时接收人 | 若改成 Book scope，audience 要另存，不能只换 scope 字符串 |
| Space 含 viewer 私有字段 | 推荐拆公共 Book 与个人 BookState；同客户端同 model/id/revision 不得出现冲突内容 |
| MomentMedia sourceId 为 owner-only | projection identity/版本规则需要明确；不默认所有 viewer 内容相同 |
| Activity / FeedPlacement preparation 有写入 | 不能直接全部改成只读 materializer |
| 媒体上传前置 | readiness 必须保留，上传不放进长 DB transaction |
| 本地 composition/URL/companion | model 定义不等于 downlink 注册；保留这种自由 |

应用参考：`backend/src/moments/moments.service.ts` 的 Move；`backend/src/replies/reply-rooms.ts`；`backend/src/local-sync/bindings/loaders/{space,activity,feed-order,content}.loader.ts`。应用代码不复制到公开示例。

## 5. 验证边界

审查了独立仓库目录、主要 state machine、持久化 schema、compiler 数据模型及测试目录、后端事务/下行实现，以及上述 Oasis 路径。测试文件用于识别承诺，不等于本轮运行通过。没有运行完整 gate，没有修改 runtime，没有访问生产 DB。

达到旧版本完整替代前，每一行必须对应：Rust/SDK/adapter 测试通过，或明确 breaking change 和迁移说明。只打通第一个示例不能称为完整重写完成。
