#!/bin/zsh
# Local UI acceptance only: reuse this Mac's installed engine, never distribute this bundle.
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build
app="$PWD/.build/RecordAILibraryPreview.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
[[ -d /Applications/RecordAI.app/Contents/Resources/Engine ]] || { print -u2 '需要已安装的 RecordAI 引擎，仅用于本机预览。'; exit 1; }
python3 - <<'PY'
from pathlib import Path
Path('.build/LibraryPreviewTypes.swift').write_text(Path('Sources/CoHearTranscribeApp.swift').read_text().replace('@main\n', ''))
PY
sources=(Sources/*.swift)
sources=(${sources:#Sources/CoHearTranscribeApp.swift})
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
    $sources .build/LibraryPreviewTypes.swift Tests/LibraryManagementPreview.swift -o "$app/Contents/MacOS/RecordAIPreview.new"
mv "$app/Contents/MacOS/RecordAIPreview.new" "$app/Contents/MacOS/RecordAIPreview"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
    Sources/AgentSchema.swift Sources/RecordAIControl.swift Sources/AgentSetup.swift Native/AgentCLI/main.swift -o "$app/Contents/MacOS/recordai"
cp Resources/ASRModels.json "$app/Contents/Resources/"
ditto Resources/AgentSkill "$app/Contents/Resources/AgentSkill"
if [[ -L "$app/Contents/Resources/Engine" ]]; then unlink "$app/Contents/Resources/Engine"; fi
if [[ ! -d "$app/Contents/Resources/Engine" ]]; then
    cp -cR /Applications/RecordAI.app/Contents/Resources/Engine "$app/Contents/Resources/Engine"
fi
cp /Applications/RecordAI.app/Contents/Resources/AppIcon.icns "$app/Contents/Resources/"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib,sys
from pathlib import Path
with Path('Resources/Info.plist').open('rb') as f: value=plistlib.load(f)
value.update(CFBundleIdentifier='com.recordai.preview.librarymanagement',CFBundleExecutable='RecordAIPreview',CFBundleName='RecordAI 资料管理预览')
with Path(sys.argv[1]).open('wb') as f: plistlib.dump(value,f)
PY
if [[ -n "${1:-}" ]]; then
    [[ -f "$1/.recordai-isolated-test" ]] || { print -u2 '只能使用隔离验收目录'; exit 1; }
    print -r -- "$1" > "$app/Contents/Resources/LibraryPreviewRoot.txt"
fi
codesign --force --sign - "$app/Contents/MacOS/recordai"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
print "本机隔离验收预览：$app"
