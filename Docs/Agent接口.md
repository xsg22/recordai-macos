# TalkTuck Agent 接口与接入验证

以下描述当前源码的接口；已发布包与新命名接口的区别见[统一命名迁移](统一命名迁移.md)。用户入口为首次非空定稿的引导卡、“设置 → Agent 与数据”和交付页的“复制接入提示词”。无需在 App 中选择 Agent。

## 取得 Skill

复制的提示词使用 App 与数据的真实位置。例如安装在默认目录时：

```sh
'/Applications/TalkTuck.app/Contents/MacOS/talktuck' setup --json
```

可加 `--root '/实际资料目录/AgentData'`。返回 `schemaVersion`、`appVersion`、`connection`、`installation`、`skill.files`、`verification` 和 `capabilities`。`skill.files` 是相对路径到 UTF-8 内容的映射：

- `SKILL.md`：查询与显式录音控制流程。
- `references/connection.json`：实际 CLI/App/数据目录与可选 stdio MCP 配置。
- `agents/openai.yaml`：可选 Codex 展示信息。

由当前 Agent 确认其版本、安装范围、受支持目录或导入方式后安装。不要求先注册 MCP；能运行 CLI 即可查询。已有同名非自有技能不覆盖。无法访问本机的云端会话需要说明限制。

同一份信息也由只读 MCP 工具 `get_agent_setup`、资源 `talktuck://setup` 提供。App 发布的 `AgentData/SETUP.md` 包含 CLI 入口、Skill 的本机文件位置与连接 JSON，供只能读文件的 Agent 使用。读取安装说明不创建数据目录、不启动 App、不安装 Skill、不开始录音。

## 查询与控制

| CLI | MCP | 行为 |
| --- | --- | --- |
| `list` | `list_recordings` | 列出录音；暂无单独搜索接口 |
| `read UUID` | `get_recording` / `get_transcript` | 定稿、段落、发言人及就绪状态 |
| `audio UUID` | `get_audio_files` | 音频引用，不上传音频 |
| `changes --since N` | `get_changes` | 增量事件；需要重同步时重新列出 |
| `status` | `get_recording_status` | 实际采集状态，必须检查 `available` |
| `result COMMAND_UUID` | `get_command_result`（`commandId`） | 读取 accepted/rejected 回执；不等于实际采集成功 |
| `control ACTION` | `control_recording` | 异步控制；唯一非只读工具 |

`read` 可选 `--format json|txt|md|srt`。只有明确需要实时草稿时才使用 `--include-preview` / `includePreview`。`transcriptionReady` 表示正文已保存；分人仍在进行时 `ready` 可以为 false。部分分析失败不隐藏已有定稿。

正式客户端在应用启动时恢复已登录账号并发布对应的本机索引，不依赖主窗口显示或获得焦点。已验证的未过期账号缓存可在离线时恢复；若登录钥匙串尚未解锁，客户端在后台重试。登出、过期凭据和切换账号仍按账号隔离，不为后台查询开放其他账号的录音。只读查询不主动打开窗口或开始录音。

启动身份尚未确定时保留上次有效快照，恢复后统一发布最终账号范围，避免短暂空列表和错误的删除事件。云同步队列损坏会暂停网络同步，但不遮挡已验证账号的本地转录。

只有用户明确要求时才开始录音：

```sh
'/Applications/TalkTuck.app/Contents/MacOS/talktuck' control start_recording --launch
```

`--launch` 仅允许开始动作、当前真实安装包和默认资料目录；自定义测试目录会被拒绝，避免唤起其他实例。MCP 使用 `action=start_recording, launch=true`。首次 macOS 采集授权需要用户完成。

支持的动作还有 `pause_recording`、`resume_recording`、`stop_recording`、`retry_transcription`。先读取命令回执，再检查新鲜状态：`available=true` 且实际 `recording`/`paused` 与请求匹配，才可以报告完成。停止时等待 `recording=false, preparing=false`；最终转录另行等待。状态超过 5 秒或进程已不存在则不可用；队列中超过 30 秒的未执行命令拒绝执行，Agent 应在查询状态后再决定是否重试。

## 验证

```sh
python3 Scripts/test-recording-entry.py
python3 Scripts/test-ui-contracts.py
python3 Scripts/test-agent-setup.py
zsh Scripts/preview-ui.zsh --build-only
```

新增协议测试实际编译一个临时 App 包内的 CLI，复制正式 Skill 资源，执行 CLI/MCP 安装说明、工具、资源、转录查询及错误分支，再在隔离的 Agent 目录写入返回文件并查询转录。不访问个人技能配置，不启动真实录音。首次引导的失败/草稿排除、忙碌延迟、持久化、稍后/重开由 AppState 回归覆盖。

历史原生 UI 与剪贴板记录已按摘要校验归档到仓库外。当前验证须按[UI 验收](UI验收.md)重新绑定；隔离接口测试不代表真实各品牌 Agent 加载、硬件录音、系统权限或全页面验收通过。

## 资料管理查询

`list` 增加 `--query TEXT`、`--group UUID` 与 `--ungrouped`。MCP `list_recordings` 对应可选的 `query`、`groupId`、`ungrouped`。搜索覆盖标题、正文和分组名。

`read.organization` 为兼容旧版本的可选字段，包含 `group` 与独立 `revision`。整理改动发布 `kind=metadata` 事件和 `metadataRevision`，正文 `revision` 与 `contentDigest` 不变；内容变化仍发布 updated。客户端收到 metadata 时刷新分组，不必重新生成相同正文的分析。

移除分组只解除关联，原音与正文保留。查询接口仍只读，不包含历史 AI 总结、笔记或凭据，也不启动采集。已发布版本与当前源码应分别查询各自的 `setup --json`，以该版本的能力声明为准。

标签功能已从当前开发范围移除；旧开发参数 `--tag` / `tagIds` 会被拒绝，公开快照不再返回 tags 字段。旧数据读取时忽略多余字段，原音、分组、正文保留。

时间点功能也已撤回；当前公开快照不再返回 bookmarks 字段，也不检索时间点名称或备注。旧字段只作兼容忽略，正文自带时间戳和音轨引用不变。
