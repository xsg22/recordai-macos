# RecordAI 0.17.0 功能验证版

源码验证基线：`8d8147d3028f7e79301ec25599b5a339f5d09766`。应用与资源摘要由 [功能发布绑定](../../design-v2/validation/functional-release-binding.json) 记录；后续证据和文档提交不改变实际应用输入。本版延续主功能通过后发布功能验证 prerelease 的授权，不将完整设计册视觉验收记为完成。

## 正式候选包验收

- [构建与回归日志](build-and-verification.log)：14 组录音/数据回归、8 组账号与旧工具类契约、库/分组/CLI/MCP/Skill 集成、碎段与 9 项离线报告、本地化及 4 项语言策略验证通过。契约测试中的 mock 不代表真实账号、硬件或服务结果。
- [原生客户端端到端结果](import-e2e/result.json)：在新隔离 Home 运行实际候选应用，从系统面板导入 31.296 秒双人中文合成语音，点击主转录按钮，实际调用包内引擎并完成 4 段转录与发言人分析。
- 点击第二段真实回听，播放后在该段终点 13.85 秒自动暂停。修正“测试组完成首页交付”为“设计组完成首页交付”，段落 ID、时间、发言人、原始字幕和音频哈希不变。
- 实际通过原生保存面板导出[原始 Markdown](import-e2e/合成会议导入验收-原始识别.md)、[校正 Markdown](import-e2e/合成会议导入验收-人工校正.md)、[原始 SRT](import-e2e/合成会议导入验收.srt)，并逐字比较校正差异。
- [分组与 Agent 验证](agent-verification.json)：创建“产品讨论”并归档，使用包内 CLI/MCP 实际读取校正后的正文与分组，验证 setup 版本、Skill 文件和接口一致性；没有启动录音。
- [包内英文/混合实测](packaged-bilingual.log)：实际用候选包内 Qwen 完成[英文](english/report.json)与[中英混合](mixed/report.json)的转录、SRT 和发言人对齐，正文重组一致；不是用替代引擎输出冒充包内结果。
- [正式包英文界面](settings-en.ax.txt)与[数据保全](locale-data-invariant.json)：切换界面后，已保存的会议与 Agent 快照文件字节保持不变。
- [候选包校验](candidate-package.json)：应用签名、arm64、内置 Python 3.12 与语音引擎、CLI/Skill、英文资源及 DMG/PKG 内容验证通过。

音频只使用可分享的合成样本。模型在 APFS 克隆的隔离资料目录内复用，不修改个人库。识别仍有误差：中文样本将一处“设计组”识别为“测试组”，英文样本将 “offline” 识别为 “a flying”。这些结果只支持功能验证，不代表真实会议总体准确率。

## Windows

[Windows Runner 记录](windows-ci.json)与[GitHub 工作流](https://github.com/xsg22/recordai-macos/actions/runs/41428182612)：15 项契约测试在 Windows Server 2025 x64 / Python 3.12.10 上通过，PyAudioWPatch 安装成功。设备探测结果为 `unavailable`，没有进行真实采集；可选引擎推理任务为 skipped。因此没有 Windows 原生推理、显卡性能或声卡采集通过的结论，也没有 Windows 安装包。

## 复验与恢复

重复打包使用 `Scripts/release.zsh --candidate`。实际 UI 验收可用 `Scripts/prepare-release-acceptance.py` 启动新的隔离 Home，完成界面操作并保存截图、AX、导出文件后，再用 `Scripts/record-functional-acceptance.py` 校验并绑定证据；它不会生成虚构的 UI 操作结果。`Scripts/check-functional-acceptance.py` 同时核对主流程和本次中英文证据。

本次未重新验证真实麦克风/系统音频采集、首次 TCC、外部 OAuth 或远端写入，也没有完成全部设计稿页面的视觉签署。升级不删除录音和模型；需要回退时使用保留的 0.16.2 安装包，勿删除个人资料目录。
