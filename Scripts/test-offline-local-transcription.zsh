#!/bin/zsh
# Usage: test-offline-local-transcription.zsh ENGINE_DIR MODEL_ROOT
set -euo pipefail
cd "${0:A:h:h}"
engineDir="${1:?Pass the installed engine directory}"
modelRoot="${2:?Pass the installed model root}"
[[ -x "$engineDir/qwen-asr" && -x "$engineDir/paraformer-live" && -f "$modelRoot/Qwen3ASR/model.safetensors" ]]
mkdir -p .build
runDir="$(mktemp -d "$PWD/.build/offline-local-test.XXXXXX")"
# Extract the production value types without pulling in the UI/library extensions.
python3 - "$runDir/Paragraph.swift" <<'PY'
from pathlib import Path
import sys
s=Path('Sources/TranscriptDocument.swift').read_text()
Path(sys.argv[1]).write_text(s[:s.index('struct LiveUtterance')]+s[s.index('struct TranscriptReadingGroup'):])
PY
xcrun swiftc -swift-version 5 -parse-as-library Sources/TranscriptionEngine.swift "$runDir/Paragraph.swift" Tests/OfflineLocalTranscriptionSmoke.swift -o "$runDir/offline-asr"
say -v Tingting -r 155 -o "$runDir/speech.aiff" '今天验证本地转录。不登录账号，断开网络，原始录音仍然保存在本机。'
afconvert -f WAVE -d LEI16@16000 -c 1 "$runDir/speech.aiff" "$runDir/speech.wav"
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 /usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' "$runDir/offline-asr" "$engineDir/qwen-asr" "$modelRoot/Qwen3ASR" "$runDir/speech.wav" "$runDir/report.json"
print "Evidence: $runDir/report.json"
