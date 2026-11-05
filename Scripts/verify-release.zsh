#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

releaseVersion="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
appBundle="${TALKTUCK_BUILD_APP_PATH:-$PWD/.build/release-${releaseVersion//./}/TalkTuck.app}"
imagePath="$PWD/dist/TalkTuck-${releaseVersion}-arm64.dmg"
packagePath="$PWD/dist/TalkTuck-${releaseVersion}-arm64.pkg"
verificationRoot="$(mktemp -d "${TMPDIR:-/tmp}/talktuck-package-verify.XXXXXX")"
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
    [[ "$(lipo -archs "$bundle/Contents/MacOS/TalkTuckApp")" == arm64 ]]
    [[ -x "$bundle/Contents/MacOS/talktuck" ]]
    [[ -f "$bundle/Contents/Resources/AppIcon.icns" ]]
    cmp Resources/AppIcon.png "$bundle/Contents/Resources/AppIcon.png"
    [[ -f "$bundle/Contents/Resources/AgentSkill/talktuck/SKILL.md" ]]
    cmp Resources/AgentSkill/talktuck/SKILL.md "$bundle/Contents/Resources/AgentSkill/talktuck/SKILL.md"
    "$bundle/Contents/MacOS/talktuck" setup --json > "$verificationRoot/agent-setup.json"
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
(cd dist && shasum -c "TalkTuck-${releaseVersion}-arm64.dmg.sha256" && shasum -c "TalkTuck-${releaseVersion}-arm64.pkg.sha256")
hdiutil verify "$imagePath"
mkdir "$mountPath"
hdiutil attach -readonly -nobrowse -mountpoint "$mountPath" "$imagePath" >/dev/null
mountAttached=1
verify_app "$mountPath/TalkTuck.app"
cmp "$appBundle/Contents/MacOS/TalkTuckApp" "$mountPath/TalkTuck.app/Contents/MacOS/TalkTuckApp"
cmp "$appBundle/Contents/MacOS/talktuck" "$mountPath/TalkTuck.app/Contents/MacOS/talktuck"
pkgutil --expand-full "$packagePath" "$verificationRoot/package"
packagedApp="$verificationRoot/package/Payload/TalkTuck.app"
verify_app "$packagedApp"
cmp "$appBundle/Contents/MacOS/TalkTuckApp" "$packagedApp/Contents/MacOS/TalkTuckApp"
cmp "$appBundle/Contents/MacOS/talktuck" "$packagedApp/Contents/MacOS/talktuck"
cmp "$appBundle/Contents/Resources/Engine/ASR/qwen-asr" "$packagedApp/Contents/Resources/Engine/ASR/qwen-asr"
print "PASS: $releaseVersion 的签名、架构、内置 Python 3.12 与语音引擎、DMG/PKG 内容和校验值。"
