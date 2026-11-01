#!/bin/zsh
# Explicit tag publication; GitHub builds and verifies fresh packages before release.
set -euo pipefail
cd "${0:A:h:h}"
[[ $# == 1 ]] || { print -u2 '用法：zsh Scripts/publish-functional-release.zsh v0.16.0-functional.1'; exit 2; }
releaseTag="$1"
releaseVersion="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
python3 - "$releaseVersion" "$releaseTag" <<'PY'
import re, sys
assert re.fullmatch(r'v' + re.escape(sys.argv[1]) + r'-functional\.[1-9][0-9]*', sys.argv[2]), '标签必须对应当前版本的 functional 预发布'
PY
[[ -z "$(git status --porcelain)" ]] || { print -u2 '请先提交发布源码与验证材料，工作区必须干净。'; exit 1; }
python3 Scripts/check-functional-acceptance.py
releaseHead="$(git rev-parse HEAD)"
if git rev-parse --verify "$releaseTag^{commit}" >/dev/null 2>&1; then
    [[ "$(git rev-parse "$releaseTag^{commit}")" == "$releaseHead" ]] || { print -u2 '已有标签指向其他版本，不覆盖。'; exit 1; }
else
    git tag -a "$releaseTag" -m "RecordAI $releaseVersion functional prerelease"
fi
git push "${RECORD_AI_GIT_REMOTE:-origin}" "refs/tags/$releaseTag"
print '标签已推送；请检查 Build macOS release assets，只有构建、回归及包校验通过后才会出现 GitHub 安装包。'
