#!/bin/zsh
# Usage: RECORD_AI_TEST_ROOT=/path/on/external/disk test-offline-local-transcription.zsh ENGINE_DIR MODEL_ROOT
set -euo pipefail
projectRoot="${0:A:h:h}"
engineDir="${1:?Pass the installed engine directory}"
modelRoot="${2:?Pass the installed model root}"
engineDir="${engineDir:A}"
modelRoot="${modelRoot:A}"
[[ -x "$engineDir/qwen-asr" && -x "$engineDir/paraformer-live" && -f "$modelRoot/Qwen3ASR/model.safetensors" ]]
testRoot="${RECORD_AI_TEST_ROOT:?Set RECORD_AI_TEST_ROOT to an existing writable external test directory}"
[[ -d "$testRoot" && -w "$testRoot" ]] || { print -u2 'RECORD_AI_TEST_ROOT must already exist and be writable'; exit 1; }
runDir="$(mktemp -d "${testRoot%/}/offline-local-test.XXXXXX")"
# Extract the production value types without pulling in the UI/library extensions.
python3 - "$projectRoot/Sources/TranscriptDocument.swift" "$runDir/Paragraph.swift" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
Path(sys.argv[2]).write_text(s[:s.index('struct LiveUtterance')]+s[s.index('struct TranscriptReadingGroup'):])
PY
mkdir -p "$runDir/tmp" "$runDir/cache" "$runDir/xdg" "$runDir/huggingface"
cd "$runDir"
export TMPDIR=tmp PYTHONDONTWRITEBYTECODE=1 XDG_CACHE_HOME="$runDir/xdg" HF_HOME="$runDir/huggingface"
xcrun swiftc -module-cache-path cache -swift-version 5 -parse-as-library "$projectRoot/Sources/BalancedWatchSync.swift" "$projectRoot/Sources/CanonicalAudioReader.swift" "$projectRoot/Sources/CanonicalAudioInput.swift" "$projectRoot/Sources/TranscriptionEngine.swift" Paragraph.swift "$projectRoot/Tests/OfflineLocalTranscriptionSmoke.swift" -o offline-asr
say -v Tingting -r 155 -o speech.aiff '今天验证本地转录。不登录账号，断开网络，原始录音仍然保存在本机。'
afconvert -f WAVE -d LEI16@16000 -c 1 speech.aiff speech.wav
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 /usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' ./offline-asr "$engineDir/qwen-asr" "$modelRoot/Qwen3ASR" "$runDir/speech.wav" "$runDir/report.json"
print "Evidence: $runDir/report.json"
