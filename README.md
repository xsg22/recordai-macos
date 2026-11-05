# TalkTuck for macOS

把声音留下来，把转录交给你习惯的 Agent。

本仓库公开 TalkTuck 的 macOS 原生客户端、构建脚本与相关文档。iPhone、Apple Watch 和服务端属于独立工程。

[产品介绍](https://xueshengguo.com/apps/talktuck/) · [个人主页](https://xueshengguo.com/) · [GitHub Releases](https://github.com/xsg22/talktuck/releases)

**[下载 0.17.3（55）](https://github.com/xsg22/talktuck/releases/tag/v0.17.3)** · [DMG](https://github.com/xsg22/talktuck/releases/download/v0.17.3/TalkTuck-0.17.3-arm64.dmg) · [PKG](https://github.com/xsg22/talktuck/releases/download/v0.17.3/TalkTuck-0.17.3-arm64.pkg)

适用于 Apple Silicon、macOS 14 或更新版本。Python 3.12 和语音引擎随包提供，首次使用仍需下载模型。当前发布为主功能验证版，采用本地签名，尚未 Apple 公证。

本版的 App、命令与 Skill 统一使用 TalkTuck / `talktuck`。升级后请在应用内重新复制 Agent 接入提示词，按实际安装路径更新接入。

## 录音、转录和分组

- 麦克风、系统声音或两路一起录，录音中可分别控制音源。
- mini 悬浮窗显示实时字幕，支持暂停、继续和停止保存。
- 录音界面选择普通话、粤语、英语或中英自动；粤语支持实时字幕和录完后的定稿。
- 个人热词支持批量添加，候选词经确认后才用于转录。
- 导入音频、按段回听、校正转录，导出 Markdown、文本或字幕。
- 用分组、搜索和星标管理录音；原音与文字保存在本机。
- 通过 Skill、CLI 或 MCP，让本机 Agent 查询定稿并按需整理重点。

以下为 0.17.3（55）正式客户端的实际截图。转录示例来自公开的 Google FLEURS 粤语朗读测试，未人工修改识别文字；搜索已限定为这条公开测试录音，避免展示私人资料。识别仍可能出错，请结合原音核对。数据集采用 CC BY 4.0，见 [Google FLEURS](https://huggingface.co/datasets/google/fleurs)。

![TalkTuck 最新资料库、音频波形、逐段回听与分组](Docs/images/talktuck-macos/library-0173.jpg)

![TalkTuck 录音界面的普通话、粤语、英语和中英自动选择](Docs/images/talktuck-macos/languages-0173.jpg)

![TalkTuck 录音与转录设置](Docs/images/talktuck-macos/settings-0173.jpg)

界面支持简体中文和 English，与转录语言分别设置。TalkTuck 账号、第三方账号、个人热词与 Agent 接入在设置中分别管理。

## Agent 接入

在应用中复制接入提示词，发给当前使用的本机 Agent。由 Agent 获取 Skill、安装到自己的环境，并分别确认加载和转录查询；读取内容不需要启动录音或上传原音。

当前源码的命令名与 Skill 名为 `talktuck`，MCP 资源使用 `talktuck://`。CLI 的 `setup --json` 提供实际路径与完整安装文件，避免手工猜测位置。App 在后台启动且未打开主窗口时也可查询已保存定稿；系统钥匙串暂不可用时自动重试账号恢复。开始录音需要用户明确指令，队列受理与实际录音状态分别查询。详见[接口说明](Docs/Agent接口.md)。

## 开发与验证

需要 Apple Silicon、macOS 14+、Xcode 命令行工具和 Python 3.12。官方账号组件放入配置的依赖目录，构建会检查固定版本和 SHA-256。模型、依赖二进制、安装包及用户资料不纳入 Git。

在独立构建工作区为 `.build`、`dist` 和依赖目录配置外部输出位置，并显式设置 `TMPDIR`、工具缓存；已有目录不得被构建脚本自动迁移。详见[构建与发布](Docs/发布流程.md)。

```zsh
python3 Scripts/test-recording-entry.py
zsh Scripts/test-library-management.zsh
zsh Scripts/release.zsh --candidate
```

本地候选构建不等于发布。完整 UI 与主功能发布门禁继续保留；历史执行原件已归档，不能作为新命名版本的通过证据。见[本轮迁移说明](Docs/统一命名迁移.md)和[UI 验收状态](Docs/UI验收.md)。

本版功能变化与验证边界见 [0.17.3 发布说明](Docs/releases/0.17.3.md)；不同构建的实测与下载记录分别保存在[本轮验证记录](Docs/validation/current/README.md)。

## TalkTuck 账号同步

使用 TalkTuck 账号登录后，默认自动同步本机全部录音资料：标题、转录定稿、发言人、星标、分组和原始音频，无需逐条勾选。新录音结束后自动加入同步；没有转录的原音也会保存到账号。录音中的临时字幕不上传。

可在设置中暂停全部同步，暂停状态会保留；恢复后自动补传离线修改。相同账号会拉取另一端的资料和原音，不同账号的数据保持隔离。双方同时修改时保留冲突版本，由用户选择。第三方工作区分享仍需单独操作。

## 联系方式

邮箱：[xsgnzb1@gmail.com](mailto:xsgnzb1@gmail.com)

微信公众号：**李昂的数字之旅**。

<img src="Docs/images/wechat-qr.png" alt="李昂的数字之旅公众号二维码" width="240">
