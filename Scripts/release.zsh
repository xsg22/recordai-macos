#!/bin/zsh
# Prepare local packages; GitHub publishing remains an explicit workflow input.
set -euo pipefail
cd "${0:A:h:h}"
candidate=0
if [[ "${1:-}" == --candidate && $# == 1 ]]; then candidate=1
elif (( $# )); then print -u2 '用法：zsh Scripts/release.zsh [--candidate]'; exit 2
fi
python3 -c 'import sys; assert sys.version_info[:2] == (3, 12), "请使用 Python 3.12 构建；最终用户不需要安装 Python"'
if (( ! candidate )); then python3 Scripts/check-ui-acceptance.py; fi
mkdir -p .build
python3 Scripts/check-localization.py
zsh Scripts/test-localization.zsh
python3 Tests/LanguagePolicySmoke.py
export RECORD_AI_UI_LANGUAGE=zh-Hans
python3 Scripts/test-recording-entry.py
python3 Scripts/test-ui-contracts.py
python3 Scripts/test-agent-setup.py
zsh Scripts/test-library-management.zsh
if [[ ! -x .vendor/dws/dws || ! -x .vendor/lark-cli/lark-cli ]]; then zsh Scripts/prepare-account-components.zsh; fi
releaseVersion="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
export RECORD_AI_BUILD_APP_PATH="${RECORD_AI_BUILD_APP_PATH:-$PWD/.build/release-${releaseVersion//./}/TalkTuck.app}"
COHEAR_STAGE_ONLY=1 zsh Scripts/build.zsh
zsh Scripts/verify-release.zsh
if (( candidate )); then print '仅完成本地候选包校验，不触发发布。功能验证版须另走主功能门禁和 functional 标签流程。'
else print '本地交付包已校验。GitHub 发布请运行 Build macOS release assets 并启用 publish_release。'
fi
