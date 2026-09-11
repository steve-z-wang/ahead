# Rust schema compiler

[English](README.md) | [简体中文](README.zh-CN.md)

`cargo run -p lfs-compiler -- compile INPUT_DIR OUTPUT_DIR` 按排序后的顺序读取 `.model` 文件，输出 `schema.json`、`backend.json`、`generated.ts`、`generated.dart` 和 `mutation-history.json`。生成的 API 只负责转换与转发；状态转换仍在 Rust runtime 中执行。Dart 输出导入 `package:local_first_state/local_first_state.dart`。TypeScript 接受 JS package 实现的结构化 `ClientPort` 接口。

支持的声明包括 Model、enum、prerequisite、具名 Mutation、标量及可空标量字段、标量列表、复合 Identity、唯一约束组、引用（含具名引用和级联删除）、反向关系元数据、prerequisite 调用、Mutation slot 绑定、可选及列表 slot、受限更新字段、Mutation version 和 sequence path。未知语法会报错并指出源码位置。Schema descriptor 携带规范化后的 requirements、prerequisites 和客户端策略，供 runtime 使用。

Dart patch 使用 `Present<T>`：省略表示不变，`Present(null)` 表示显式清空可空字段。TypeScript 使用可选属性及 `exactOptionalPropertyTypes`；省略的字段会从生成的 wire value 中移除。Identity 与 state 分离。UUID 保持为字符串，DateTime 与 UTC wire 字符串相互转换。Mutation builder 按声明的 slot 顺序输出操作。

默认输出的 history 会在多次运行间保留。Backend descriptor 包含所有历史版本，每个版本都有 input schema 和已知字段集合。同版本修改必须向后兼容：可以添加可空的 create 字段以及额外允许的 patch/enum 值；添加必需 create 字段、移除字段、改变类型、重排 slot、改变绑定或依赖策略则必须新增版本。版本号不能降低，已保留的 Mutation 不能消失。

`--mutation-history FILE` 选择已提交的 history；如果显式指定的文件不存在，则需要 `--initialize-mutation-history`，且该选项只接受版本 1 的声明。`--schema-fence FILE` 选择用于检查的已发布 schema，默认使用现有输出 `schema.json`。已发布的 Model/字段名不能移除。更广泛的 Identity/类型/可空性检查仍留待后续实现。所有检查均在替换生成文件前完成。

`integration/generated-api/verify.sh` 运行 Rust parser/history/CLI 测试、TypeScript 正例和预期报错的类型 fixture、JS native addon 集成、Dart analysis，以及 Dart native library 集成。请先构建根目录的 native libraries。

History JSON 使用 Rust descriptor 格式，不负责导入旧 Dart compiler 的 history 编码。两种语言都会生成强类型查询选项及正向/反向关系访问器。单值反向关系要求外键具有唯一约束。通用源码转换预期接收 runtime 已验证的完整 Record。语义诊断目前定位到解析器完成解析后的所在位置；词法/语法错误则定位到出错的 token。
