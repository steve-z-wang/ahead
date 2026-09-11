# ACK 先于 Pull 到达

[English](README.md) | [简体中文](README.zh-CN.md)

初始权威状态：Entry.text = A。本地 M1 写入 B，M2 写入 C。M1 被接受，对应 Book Channel 的 Checkpoint 为 11。Cursor 为 10 时，可见文本为 C，M1 仍待结算。Cursor 达到 11 时，只结算已就绪的 accepted prefix 中的 batch；如果 M2 仍待处理，重放后文本仍为 C。还需在 Pull 先于 ACK 到达，以及每个持久化边界后重新打开存储的情况下重复验证。
