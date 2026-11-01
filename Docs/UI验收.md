# UI 对照验收

设计源：[完整界面设计册](design-v2/index.html)。页面编号与 [manifest.json](design-v2/manifest.json) 一一对应；验收记录位于 [acceptance.json](design-v2/acceptance.json)。

当前结论：未完成，未宣称 100% 还原。44 项均有独立记录；43 页已补拍并绑定当前源码，第 43 项真实系统菜单尚缺证据。Mac 当前可操作，已请求展开真实菜单。模型弹窗尺寸、后台说明卡片位置和执行阶段夹具已修正；剩余视觉与交互签核见 [review-progress.json](design-v2/validation/review-progress.json)。

22 组隔离回归/契约测试及本地候选包内容校验已通过，证据见 [data-regression.json](design-v2/validation/data-regression.json)、[ui-contracts.json](design-v2/validation/ui-contracts.json) 和 [candidate-package.json](design-v2/validation/candidate-package.json)。另有真实候选客户端的[音频导入端到端实测](design-v2/validation/import-e2e/README.md)，涵盖内置引擎、分人、回放、校正和导出。这些结果不替代最终视觉签核，也不表示真实 OAuth、远端发文或麦克风采集已经验收。

| 编号 | 页面 / 状态 | 最终验收 |
| --- | --- | --- |
| 01-home | 首页 · 首次使用 | 待验收 |
| 02-library | 会议详情 · 正文与摘要 | 待验收 |
| 03-starred | 星标录音 | 待验收 |
| 04-search | 搜索 · 无结果 | 待验收 |
| 05-trash | 回收站 | 待验收 |
| 06-recording | 录音中 · 实时转写 | 待验收 |
| 07-paused | 录音已暂停 | 待验收 |
| 08-background | 后台录音 · 精简视图 | 待验收 |
| 09-no-microphone | 无麦克风 | 待验收 |
| 10-device-lost | 设备断开 · 可重试 | 待验收 |
| 11-transcribing | 转录进行中 | 待验收 |
| 12-mini | mini · 录音中 | 待验收 |
| 13-mini-paused | mini · 暂停 | 待验收 |
| 14-mini-error | mini · 设备异常 | 待验收 |
| 15-model-setup | 模型 · 首次下载 | 待验收 |
| 16-model-progress | 模型 · 下载与校验 | 待验收 |
| 17-model-error | 模型 · 失败与重试 | 待验收 |
| 18-settings-recording | 设置 · 录音与转录 | 待验收 |
| 19-settings-models | 设置 · 本地助手模型 | 待验收 |
| 20-account-dingtalk | 账号 · 钉钉 | 待验收 |
| 21-account-feishu | 账号 · 飞书 | 待验收 |
| 22-account-notion | 账号 · Notion | 待验收 |
| 23-account-connected | 账号 · 已连接 | 待验收 |
| 24-settings-data | 设置 · Agent 与本机资料 | 待验收 |
| 25-delivery | 导出与交付 | 待验收 |
| 26-sync-preview | 同步 · 内容预览 | 待验收 |
| 27-sync-progress | 同步 · 进行中 | 待验收 |
| 28-sync-result | 同步 · 成功与失败 | 待验收 |
| 29-recovery | 恢复 · 可恢复片段 | 待验收 |
| 30-recovery-empty | 恢复 · 无未登记片段 | 待验收 |
| 31-execution | 执行追踪 | 待验收 |
| 32-paragraph-edit | 编辑逐字稿段落 | 待验收 |
| 33-speaker | 发言人 · 改名与合并 | 待验收 |
| 34-action-item | 行动项 · 添加与编辑 | 待验收 |
| 35-delete-confirm | 移入回收站确认 | 待验收 |
| 36-quit-confirm | 录音中退出确认 | 待验收 |
| 37-notes | 笔记与本地助手 | 待验收 |
| 38-assistant | 助手 · 对话与 Live Q&A | 待验收 |
| 39-narrow | 窄窗口 · 摘要抽屉 | 待验收 |
| 40-dark | 深色模式 | 待验收 |
| 41-import | 导入音频 · 系统文件选择器 | 待验收 |
| 42-export | 导出 · 系统保存面板 | 待验收 |
| 43-menu-bar | 菜单栏录音控制 | 待验收 |
| 44-errors | 通用错误与授权等待 | 待验收 |

## 证据要求

- 逐页保存客户端实际截图；设计图与实现截图明确区分。
- 固定演示资料、窗口尺寸和外观后对照布局、字体、颜色、留白、控件与各状态。
- 每页对应交互必须验证；仅编译通过、存在视图类型或绿色测试标记不足以证明视觉通过。
- 模型、账号和外部授权页面使用可控演示状态验证界面；真实传输与授权边界仍须由业务测试证明。
- 所有未通过项处理后，重新生成 README 最终截图，构建、校验并发布安装包。
- 用户已另行允许主功能通过后先发布功能验证 prerelease；该通道明确保留 UI 未完成状态，不替代本表的逐页验收。
- 新安装包确认可用后，仅清理本项目过期包与冗余打包中间产物，保留交付包和必要回滚版本。

隔离预览：`zsh Scripts/preview-ui.zsh`。只使用临时目录中的合成音频与演示资料。
