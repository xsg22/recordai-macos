# TalkTuck 界面实现

原生入口位于 `Sources/CoHearTranscribeApp.swift`，共用主题组件位于 `Sources/DesignSystem.swift`。录音、转录、分组、个人热词、账号与 Agent 设置使用同一组主题和字体规则。

图标来自 `Resources/AppIcon.png`，打包生成 ICNS 并复制 PNG。侧栏直接读取包内 PNG，包校验同时核对图标内容。

历史布局检查不作为当前源码的验收结论。当前页面和证据需求见 `manifest.json`、`acceptance.json` 与 `../UI验收.md`。
