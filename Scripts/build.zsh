#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
root="$PWD"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
mkdir -p .vendor .models .build dist
[[ -x .vendor/dws/dws && -x .vendor/lark-cli/lark-cli ]] || { print -u2 '缺少固定版本的官方账号组件：.vendor/dws/dws 或 .vendor/lark-cli/lark-cli'; exit 1; }
[[ "$(shasum -a 256 .vendor/dws/dws | cut -d ' ' -f 1)" == '41eef2e626b4fe95104ad6a638536b45b51052b9754696904c6a5e159deb5ad4' ]] || { print -u2 'DWS组件校验失败'; exit 1; }
[[ "$(shasum -a 256 .vendor/lark-cli/lark-cli | cut -d ' ' -f 1)" == '558a4b3db4beb63ab71f2d2dbc42506846535bc1276f707764ff94809e8441a0' ]] || { print -u2 '飞书组件校验失败'; exit 1; }

/bin/zsh Scripts/prepare-asr.zsh
app="${RECORD_AI_BUILD_APP_PATH:-$root/.build/release/RecordAI.app}"
[[ ! -d "$app" ]] || /bin/rm -rf "$app"
mkdir -p "$app/Contents/"{MacOS,Resources/Engine,Resources/Licenses}
mkdir -p "$app/Contents/Resources/"{Accounts,Integrations}
cp .vendor/dws/dws "$app/Contents/Resources/Accounts/dws"
cp .vendor/lark-cli/lark-cli "$app/Contents/Resources/Integrations/lark-cli"
cp Resources/DWS-LICENSE.txt "$app/Contents/Resources/Licenses/dws.txt"
cp .vendor/lark-cli/LICENSE "$app/Contents/Resources/Licenses/lark-cli.txt"
xcrun swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
    -o "$app/Contents/MacOS/RecordAIApp" Sources/*.swift
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 \
    Sources/AgentSchema.swift Sources/RecordAIControl.swift Native/AgentCLI/main.swift -o "$app/Contents/MacOS/recordai"
cp Resources/Info.plist "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources/Engine/ASR"
ditto .build/qwen-runtime/qwen-asr "$app/Contents/Resources/Engine/ASR"
cp .build/paraformer-live "$app/Contents/Resources/Engine/ASR/"
cp .vendor/sherpa-runtime/sherpa_onnx/lib/{libsherpa-onnx-c-api.dylib,libonnxruntime.dylib} "$app/Contents/Resources/Engine/ASR/"
cp Resources/ASRModels.json "$app/Contents/Resources/"
ditto .build/asr-licenses "$app/Contents/Resources/Licenses/ASR"
xcrun swift Scripts/icon.swift .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
identity="${SIGN_IDENTITY:--}"
codesign --force --sign "$identity" "$app/Contents/Resources/Engine/ASR/libsherpa-onnx-c-api.dylib"
codesign --force --sign "$identity" "$app/Contents/Resources/Engine/ASR/libonnxruntime.dylib"
codesign --force --sign "$identity" "$app/Contents/Resources/Engine/ASR/paraformer-live"
codesign --force --sign "$identity" "$app/Contents/Resources/Accounts/dws"
codesign --force --sign "$identity" "$app/Contents/Resources/Integrations/lark-cli"
codesign --force --sign "$identity" "$app/Contents/MacOS/recordai"
codesign --force --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
otool -L "$app/Contents/Resources/Engine/ASR/paraformer-live" | tail -n +2 > .build/engine-linkage.txt
otool -L "$app/Contents/Resources/Engine/ASR/libsherpa-onnx-c-api.dylib" | tail -n +2 >> .build/engine-linkage.txt
otool -L "$app/Contents/Resources/Engine/ASR/qwen-asr" | tail -n +2 >> .build/engine-linkage.txt
otool -L "$app/Contents/Resources/Accounts/dws" | tail -n +2 >> .build/engine-linkage.txt
otool -L "$app/Contents/Resources/Integrations/lark-cli" | tail -n +2 >> .build/engine-linkage.txt
if rg '/opt/homebrew|/Users/' .build/engine-linkage.txt; then
    print -u2 '推理引擎依赖本机第三方动态库，不能独立分发'; exit 1
fi
# 全部构建和签名成功后才替换交付目录，失败不覆盖可用旧版。
if [[ "${COHEAR_STAGE_ONLY:-0}" != "1" ]]; then
    ditto "$app" "$root/dist/RecordAI.app.new"
    [[ ! -d "$root/dist/RecordAI.app" ]] || mv "$root/dist/RecordAI.app" "$root/.build/previous-recordai-$(date +%s).app"
    mv "$root/dist/RecordAI.app.new" "$root/dist/RecordAI.app"
    app="$root/dist/RecordAI.app"
fi
stage="$root/.build/dmg-${version}"
mkdir -p "$stage"
ditto "$app" "$stage/RecordAI.app"
ln -sfn /Applications "$stage/Applications"
cp Resources/安装说明.txt "$stage/安装说明.txt"
image="$root/dist/RecordAI-${version}-arm64.dmg"
[[ ! -f "$image" ]] || mv "$image" "$root/.build/previous.dmg"
hdiutil create -volname '倾听转录' -srcfolder "$stage" -ov -format UDZO "$image"
image_name="${image:t}"
(cd "$root/dist" && shasum -a 256 "$image_name" > "$image_name.sha256")
pkg="$root/dist/RecordAI-${version}-arm64.pkg"
pkgbuild --component "$app" --install-location /Applications \
    --identifier com.byering.recordai --version "$version" "$pkg"
pkg_name="${pkg:t}"
(cd "$root/dist" && shasum -a 256 "$pkg_name" > "$pkg_name.sha256")
print "安装包：$image"
print "安装向导：$pkg"
