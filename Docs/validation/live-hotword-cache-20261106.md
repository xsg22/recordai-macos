# 实时热词修正缓存的生产初始化

2026-11-06 真机检查发现：已确认词库存在，实时草稿仍标记为原始 Paraformer，未应用 Qwen 修正。正式 App 读取了历史测试写入的 `LivePreviewScratchDirectory`，它指向已经改变挂载点的外接盘。修正器发现目录不存在便返回，界面没有报告失败。此前验收显式注入了有效测试目录，未覆盖这条生产初始化路径。

## 修复边界

- 正式 App 使用 FileManager 提供的用户应用缓存目录，命名空间为 `com.xsg.talktuck/LiveRefinement`。不读取开发机挂载路径，不从模型目录推导缓存目录。
- 启动时清除历史测试参数 `LivePreviewScratchDirectory` 和已经没有正式调用方的 `LiveHotwordModelDirectory`。仅删除偏好值，不操作其曾指向的文件、模型或词库。
- `LivePreviewRefiner.production` 是正式调用方与验收共用的工厂。每批重新检查并准备其管理的缓存目录，允许系统清理缓存后恢复；每批临时音频仍在该批结束时清理。
- 缓存或识别失败通过回调上报，主字幕和录音继续保留。主转录页显示修正状态，mini 窗口保留字幕并显示警告图标。
- Agent 的现有 `status` / `get_recording_status` 增加可选字段：`liveRefinementState`、`liveHotwordCount`、`liveRefinementIssue`、`liveRefinementAppliedBatches`、`liveRefinementCache`、`liveRefinementCacheReady`，保持 schemaVersion 1 和旧数据读取兼容。
- `liveHotwordCount` 表示本段录音开始时已载入的确认词库快照数量；热词是识别提示，不是无条件字符串替换。仅在修正结果成功映射并保存后增加已应用批次数。

## 验证

隔离 Mac 回归 42/42 通过。新增用例通过生产工厂注入文件系统测试基址，模拟旧挂载点残留，验证旧值被清除且旧目录没有被创建；模拟缓存被系统清理后成功恢复；从实际 worker 协议验证 38 秒完整音频与确认热词均被传递；模拟目录被普通文件占用时报告 `cacheUnavailable`，不调用识别 worker、不改原字幕。

测试、报告与构建产物放外接盘。真实安装验收还需核对实际应用启动后旧配置消失、应用缓存准备成功，以及修正状态和热词数量，不能以隔离引擎通过代替真机结果。原始证据保留在 `Codex/talktuck/hotword-cache-fix-20261106`。
