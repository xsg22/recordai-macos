#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

releaseVersion="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
appBundle="${RECORD_AI_BUILD_APP_PATH:-$PWD/.build/release-${releaseVersion//./}/RecordAI.app}"
imagePath="$PWD/dist/RecordAI-${releaseVersion}-arm64.dmg"
packagePath="$PWD/dist/RecordAI-${releaseVersion}-arm64.pkg"
verificationRoot="$(mktemp -d "${TMPDIR:-/tmp}/recordai-package-verify.XXXXXX")"
mountPath="$verificationRoot/image"
mountAttached=0
cleanup() {
    if (( mountAttached )); then
        if ! hdiutil detach "$mountPath" >/dev/null; then
            print -u2 "校验卷未能卸载，保留临时目录：$verificationRoot"
            return
        fi
    fi
    /bin/rm -rf "$verificationRoot"
}
trap cleanup EXIT

verify_app() {
    local bundle="$1"
    codesign --verify --deep --strict "$bundle"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$bundle/Contents/Info.plist")" == "$releaseVersion" ]]
    [[ "$(lipo -archs "$bundle/Contents/MacOS/RecordAIApp")" == arm64 ]]
    [[ -x "$bundle/Contents/MacOS/recordai" ]]
    [[ -f "$bundle/Contents/Resources/AgentSkill/recordai/SKILL.md" ]]
    cmp Resources/AgentSkill/recordai/SKILL.md "$bundle/Contents/Resources/AgentSkill/recordai/SKILL.md"
    "$bundle/Contents/MacOS/recordai" setup --json > "$verificationRoot/agent-setup.json"
    python3 - "$verificationRoot/agent-setup.json" "$releaseVersion" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
assert value['schemaVersion'] == 1 and value['appVersion'] == sys.argv[2]
assert value['skill']['files']['SKILL.md'] and json.loads(value['skill']['files']['references/connection.json'])['cliPath']
PY
    [[ -x "$bundle/Contents/Resources/Engine/ASR/qwen-asr" ]]
    [[ -x "$bundle/Contents/Resources/Engine/ASR/paraformer-live" ]]
    [[ -f "$bundle/Contents/Resources/Engine/ASR/_internal/Python.framework/Versions/3.12/Python" ]]
    [[ -f "$bundle/Contents/Resources/ASRModels.json" ]]
    [[ -f "$bundle/Contents/Resources/Localization/en.json" ]]
    cmp Resources/Localization/en.json "$bundle/Contents/Resources/Localization/en.json"
}

verify_app "$appBundle"
(cd dist && shasum -c "RecordAI-${releaseVersion}-arm64.dmg.sha256" && shasum -c "RecordAI-${releaseVersion}-arm64.pkg.sha256")
hdiutil verify "$imagePath"
mkdir "$mountPath"
hdiutil attach -readonly -nobrowse -mountpoint "$mountPath" "$imagePath" >/dev/null
mountAttached=1
verify_app "$mountPath/RecordAI.app"
cmp "$appBundle/Contents/MacOS/RecordAIApp" "$mountPath/RecordAI.app/Contents/MacOS/RecordAIApp"
cmp "$appBundle/Contents/MacOS/recordai" "$mountPath/RecordAI.app/Contents/MacOS/recordai"
pkgutil --expand-full "$packagePath" "$verificationRoot/package"
packagedApp="$verificationRoot/package/Payload/RecordAI.app"
verify_app "$packagedApp"
cmp "$appBundle/Contents/MacOS/RecordAIApp" "$packagedApp/Contents/MacOS/RecordAIApp"
cmp "$appBundle/Contents/MacOS/recordai" "$packagedApp/Contents/MacOS/recordai"
cmp "$appBundle/Contents/Resources/Engine/ASR/qwen-asr" "$packagedApp/Contents/Resources/Engine/ASR/qwen-asr"
print "PASS: $releaseVersion 的签名、架构、内置 Python 3.12 与语音引擎、DMG/PKG 内容和校验值。"
