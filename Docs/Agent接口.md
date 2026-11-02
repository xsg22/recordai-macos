# RecordAI Agent 接口与接入验证

0.16.1 功能验证版新增。用户入口为首次非空定稿的引导卡、“设置 → Agent 与数据”和交付页的“复制接入提示词”。无需在 App 中选择 Agent。

## 取得 Skill

复制的提示词使用 App 与数据的真实位置。例如安装在默认目录时：

```sh
'/Applications/RecordAI.app/Contents/MacOS/recordai' setup --json
```

可加 `--root '/实际资料目录/AgentData'`。返回 `schemaVersion`、`appVersion`、`connection`、`installation`、`skill.files`、`verification` 和 `capabilities`。`skill.files` 是相对路径到 UTF-8 内容的映射：

- `SKILL.md`：查询与显式录音控制流程。
- `references/connection.json`：实际 CLI/App/数据目录与可选 stdio MCP 配置。
- `agents/openai.yaml`：可选 Codex 展示信息。

由当前 Agent 确认其版本、安装范围、受支持目录或导入方式后安装。不要求先注册 MCP；能运行 CLI 即可查询。已有同名非自有技能不覆盖。无法访问本机的云端会话需要说明限制。

同一份信息也由只读 MCP 工具 `get_agent_setup`、资源 `recordai://setup` 提供。App 发布的 `AgentData/SETUP.md` 包含 CLI 入口、Skill 的本机文件位置与连接 JSON，供只能读文件的 Agent 使用。读取安装说明不创建数据目录、不启动 App、不安装 Skill、不开始录音。

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

只有用户明确要求时才开始录音：

```sh
'/Applications/RecordAI.app/Contents/MacOS/recordai' control start_recording --launch
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

原生 UI 及剪贴板回读证据位于 `Docs/validation/agent-onboarding/final`。这些证据不表示真实各品牌 Agent 已加载 Skill，也不表示真实硬件录音、系统授权、所有页面或新安装包均已验收。

## 开发中的资料管理扩展

`list` 增加 `--query TEXT`、`--group UUID` 与 `--ungrouped`。MCP `list_recordings` 对应可选的 `query`、`groupId`、`ungrouped`。搜索覆盖标题、正文和分组名。

`read.organization` 为兼容旧版本的可选字段，包含 `group` 与独立 `revision`。整理改动发布 `kind=metadata` 事件和 `metadataRevision`，正文 `revision` 与 `contentDigest` 不变；内容变化仍发布 updated。客户端收到 metadata 时刷新分组，不必重新生成相同正文的分析。

移除分组只解除关联，原音与正文保留。查询接口仍只读，不包含历史 AI 总结、笔记或凭据，也不启动采集。该扩展尚未发布，现有 0.16.1 安装包不具备这些筛选参数。

标签功能已从当前开发范围移除；旧开发参数 `--tag` / `tagIds` 会被拒绝，公开快照不再返回 tags 字段。旧数据读取时忽略多余字段，原音、分组、正文保留。

时间点功能也已撤回；当前公开快照不再返回 bookmarks 字段，也不检索时间点名称或备注。旧字段只作兼容忽略，正文自带时间戳和音轨引用不变。
