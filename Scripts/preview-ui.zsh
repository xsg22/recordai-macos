#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/RecordAIPreview.app/Contents/MacOS
mkdir -p .build/RecordAIPreview.app/Contents/Resources
cp Resources/ASRModels.json .build/RecordAIPreview.app/Contents/Resources/
cp Docs/design-v2/manifest.json .build/RecordAIPreview.app/Contents/Resources/UIPages.json
mkdir -p .build/ui-preview-icon.iconset
xcrun swift Scripts/icon.swift .build/ui-preview-icon.iconset
iconutil -c icns .build/ui-preview-icon.iconset -o .build/RecordAIPreview.app/Contents/Resources/AppIcon.icns
python3 - <<'PY'
from pathlib import Path
source = Path('Sources/CoHearTranscribeApp.swift').read_text().replace('@main\n', '')
Path('.build/UIPreviewTypes.swift').write_text(source)
PY
sources=(Sources/*.swift)
sources=(${sources:#Sources/CoHearTranscribeApp.swift})
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
    $sources .build/UIPreviewTypes.swift Tests/UIPreview.swift \
    -o .build/RecordAIPreview.app/Contents/MacOS/RecordAIPreview
cat > .build/RecordAIPreview.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.recordai.preview</string>
<key>CFBundleExecutable</key><string>RecordAIPreview</string>
<key>CFBundleName</key><string>RecordAI 界面预览</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
if [[ "${1:-}" == "--build-only" ]]; then
    print '界面预览已编译：.build/RecordAIPreview.app'
else
    open .build/RecordAIPreview.app
    print '若预览已在运行，请退出后重新打开，以载入本次构建。'
fi
