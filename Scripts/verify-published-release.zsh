#!/bin/zsh
# Run after download-release-assets.py. Uses actual downloaded packages, no installation or recording.
set -euo pipefail
cd "${0:A:h:h}"
[[ $# == 4 ]] || { print -u2 'Usage: verify-published-release.zsh assetDirectory contextJSON syntheticFixtureDirectory evidenceDirectory'; exit 2; }
assetDirectory="${1:A}"
acceptanceContext="${2:A}"
fixtureDirectory="${3:A}"
evidenceDirectory="${4:A}"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
app="$PWD/.build/published-${version//./}/TalkTuck.app"
mkdir -p "$evidenceDirectory" "${app:h}"
python3 - "$assetDirectory" "$acceptanceContext" "$version" <<'PY'
from pathlib import Path
import hashlib,json,shutil,sys
assets,context,version=Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3]
backup=context.parent/'local-candidate-assets';backup.mkdir(exist_ok=True)
sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
for extension in ['dmg','pkg']:
    source=assets/f'TalkTuck-{version}-arm64.{extension}'
    expected,filename=source.with_name(source.name+'.sha256').read_text().split()
    assert filename==source.name and sha(source)==expected
    for path in [source,source.with_name(source.name+'.sha256')]:
        target=Path('dist')/path.name
        if target.exists() and sha(target)!=sha(path):
            assert not (backup/path.name).exists(),'Preserve prior candidate backup'
            target.rename(backup/path.name)
        if not target.exists():shutil.copyfile(path,target)
PY
verificationTemp="$(mktemp -d "${TMPDIR:-/tmp}/talktuck-published-verify.XXXXXX")"
attached=0
cleanup() {
    if (( attached )); then
        if ! hdiutil detach "$verificationTemp/image" >/dev/null; then
            print -u2 "Could not detach verification volume; keeping $verificationTemp"
            return
        fi
    fi
    rmdir "$verificationTemp/image" "$verificationTemp"
}
trap cleanup EXIT
mkdir "$verificationTemp/image"
hdiutil attach -readonly -nobrowse -mountpoint "$verificationTemp/image" "dist/TalkTuck-${version}-arm64.dmg" >/dev/null
attached=1
ditto "$verificationTemp/image/TalkTuck.app" "$app"
hdiutil detach "$verificationTemp/image" >/dev/null
attached=0
TALKTUCK_BUILD_APP_PATH="$app" zsh Scripts/verify-release.zsh > "$evidenceDirectory/package-verification.log" 2>&1
zsh Scripts/test-localization.zsh > "$evidenceDirectory/localization.log" 2>&1
modelRoot="$(python3 - "$acceptanceContext" <<'PY'
import json,sys
from pathlib import Path
print(Path(json.load(open(sys.argv[1]))['library'])/'Models/ASR')
PY
)"
runner="$PWD/.build/LocalizationTests.app/Contents/MacOS/test"
engine="$app/Contents/Resources/Engine/ASR/qwen-asr"
"$runner" "$engine" "$modelRoot/Qwen3ASR" "$fixtureDirectory/english.wav" en "$evidenceDirectory/english" > "$evidenceDirectory/engine.log" 2>&1
"$runner" "$engine" "$modelRoot/Qwen3ASR" "$fixtureDirectory/mixed.wav" auto "$evidenceDirectory/mixed" >> "$evidenceDirectory/engine.log" 2>&1
python3 - "$app" "$acceptanceContext" "$evidenceDirectory" "$version" <<'PY'
from pathlib import Path
import hashlib,json,subprocess,sys
app,context,out,version=Path(sys.argv[1]),json.load(open(sys.argv[2])),Path(sys.argv[3]),sys.argv[4]
base=[str(app/'Contents/MacOS/talktuck'),'--root',str(Path(context['library'])/'AgentData')]
setup=json.loads(subprocess.check_output(base+['setup','--json'],text=True));assert setup['appVersion']==version
record=json.loads(Path(context['meetingPath']).read_text())
queried=json.loads(subprocess.check_output(base+['read',record['id']],text=True));assert queried['finalText']==record['text']
requests=[dict(jsonrpc='2.0',id=1,method='initialize',params={'protocolVersion':'2025-03-26'}),
          dict(jsonrpc='2.0',id=2,method='tools/call',params={'name':'get_recording','arguments':{'id':record['id']}})]
responses=[json.loads(line) for line in subprocess.check_output(base+['mcp'],input='\n'.join(map(json.dumps,requests))+'\n',text=True).splitlines()]
assert json.loads(responses[1]['result']['content'][0]['text'])['finalText']==record['text']
for name in ['english','mixed']:
    report=json.loads((out/name/'report.json').read_text());assert report['realModelInference'] and report['textPreserved']
result=dict(version=version,packageContentsVerified=True,englishAndMixedTranscriptionAndAlignment=True,
            cliAndMcpQueryEqual=True,noHardwareCapture=True,packagedSetupVersion=setup['appVersion'],
            packagedEngineSHA256=hashlib.sha256((app/'Contents/Resources/Engine/ASR/qwen-asr').read_bytes()).hexdigest())
(out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print('PASS: actual published DMG/PKG, bundled Python/engine, English/mixed inference, alignment and CLI/MCP query')
PY
