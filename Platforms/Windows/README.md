# Windows 引擎与录音可行性验证

这是独立验证工具，还不是 Windows 客户端。默认只运行自动契约测试；不会录音或读取 RecordAI 个人资料库。需要 Windows 11 x64、Python 3.12 x64（带 `py` 启动器）。在仓库根目录运行 PowerShell：

```powershell
# 1. WAV、错误处理、设备状态、结果报告与离线引擎调用契约
.\Platforms\Windows\Run-Validation.ps1 -Mode Contracts
# 2. 仅检查 WASAPI 输入设备和系统声音 loopback，不启动采集
.\Platforms\Windows\Run-Validation.ps1 -Mode Devices
# 3. 明确启动采集；请先播放一段可分享的测试声音
.\Platforms\Windows\Run-Validation.ps1 -Mode Capture -Source system -Seconds 10
# 可选 microphone 或 both；both 分轨保存，尚未验证混音
.\Platforms\Windows\Run-Validation.ps1 -Mode Capture -Source both -Seconds 10
# 4. 用本地模型转录已知测试音频，不默认下载模型
.\Platforms\Windows\Run-Validation.ps1 -Mode Engine -Engine faster-whisper `
  -Model 'D:\models\faster-whisper-small' -Audio 'D:\tests\english.wav' `
  -Language en -Device cpu -Reference 'D:\tests\english-reference.txt'
.\Platforms\Windows\Run-Validation.ps1 -Mode Engine -Engine qwen `
  -Model 'D:\models\Qwen3-ASR-0.6B' -Audio 'D:\tests\mixed.wav' -Language auto
```

每次生成新的 `RecordAI-validation-时间` 目录。`devices.json`、`capture.json` 和 `engine.json` 记录实际操作系统、Python/依赖版本、所选设备、音频 SHA256、采样数、音量、耗时、RTF 和进程峰值内存；有人工参考文本时计算 CER/WER。报告已有时拒绝覆盖。CUDA 必须显式选择 `-Device cuda`，其依赖和可运行性需要另行实测。

`-AllowModelDownload` 才允许使用远端模型标识并下载。默认要求本地模型目录，设置离线模式。音频不会上传。依赖安装本身需要联网。原始测试输入只读，录制输出保存在新目录；驱动失败或超时会保留已接收的 `.partial.wav`。

需要指定设备时，先看 `devices.json` 的 index，再直接调用：

```powershell
.\.tools\windows-probe\Scripts\python.exe Platforms\Windows\recordai_probe.py capture `
  --source both --microphone 3 --loopback 8 --seconds 10 --output '.\my-new-test\capture.json'
```

结果必须区分：

| 结果字段/状态 | 能说明什么 |
| --- | --- |
| `inspected` | 枚举完成，尚未录音 |
| `unavailable` / `missing_dependency` / `unsupported` | 当前条件不支持测试，不能视为通过 |
| `needs_signal` / `incomplete` / `timeout` | 静音、部分采集或驱动无响应；不算成功 |
| `hardwareCaptureValidated: true` | 请求的所有轨道实际收到了非静音 PCM；不证明语音清晰或混音正确 |
| `nativeWindowsInferenceValidated: true` | 实际在 Windows 完成模型推理；准确率仍应看参考文本和人工复核 |
| `timestampSource: recording_bounds_not_alignment` | Qwen 基准暂只提供整段边界，不冒充逐句对齐 |

托管 GitHub Runner 通常没有可用声卡；工作流默认只运行契约和设备枚举，不把 CI 变绿当成采集成功。`both` 尚未验证混音、连续运行、断点恢复、暂停/恢复，也没有发言人区分。工具可以证明可行性的一部分，不代表 Windows 桌面版已经可交付。

手动触发 `Windows feasibility contracts` 工作流时，可显式选中 `run_engine`：使用 Windows 已安装的英文 TTS 生成 PCM16 测试音频，下载 tiny.en 模型，实际运行 CPU 推理并上传音频、参考文本和 JSON 报告。该用例要求 WER ≤ 0.35，仅用于识别严重回归，不代表真实会议质量。默认关闭，不依赖麦克风，也不证明系统声音采集成功。15 项契约测试已在 [Windows Runner](https://github.com/xsg22/recordai-macos/actions/runs/41428182612) 通过，设备探测为 unavailable；可选引擎任务尚未运行。Qwen、中文和混合语种仍需按本地命令分别测试。

真实 Windows 验收需补齐：无麦克风、静音、麦克风禁用/拔出、默认播放设备切换、蓝牙设备、采集超时、10 分钟以上双轨稳定性；同一中文、英文、中英混合音频分别测 CPU 的速度/内存/准确率，再决定是否引入 CUDA。测试前记录 CPU、内存和显卡；报告中的音频和转录可能含私人信息，分享前请自行检查。

实现依据：[WASAPI loopback](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording)、[PyAudioWPatch](https://github.com/s0d3s/PyAudioWPatch)、[faster-whisper](https://github.com/SYSTRAN/faster-whisper)、[Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR)。
