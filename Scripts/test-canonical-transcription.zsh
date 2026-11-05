#!/bin/zsh
# RECORD_AI_TEST_ROOT must be an existing writable directory on the test disk.
set -euo pipefail
projectRoot="${0:A:h:h}"
testRoot="${RECORD_AI_TEST_ROOT:?Set RECORD_AI_TEST_ROOT to an existing writable test directory}"
[[ -d "$testRoot" && -w "$testRoot" ]] || { print -u2 'RECORD_AI_TEST_ROOT must already exist and be writable'; exit 1; }
runDir="$(mktemp -d "${testRoot%/}/canonical-asr-test.XXXXXX")"
mkdir -p "$runDir/tmp" "$runDir/cache" "$runDir/fixtures"
python3 - "$projectRoot/Sources/TranscriptDocument.swift" "$runDir/Paragraph.swift" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
Path(sys.argv[2]).write_text(s[:s.index('struct LiveUtterance')]+s[s.index('struct TranscriptReadingGroup'):])
PY
cd "$runDir"
export TMPDIR=tmp PYTHONDONTWRITEBYTECODE=1
xcrun swiftc -module-cache-path cache -swift-version 5 -parse-as-library \
  "$projectRoot/Sources/ResilientRecordingJournal.swift" "$projectRoot/Sources/BalancedWatchSync.swift" \
  "$projectRoot/Sources/CanonicalAudioReader.swift" "$projectRoot/Sources/CanonicalAudioInput.swift" "$projectRoot/Sources/MacSegmentedTrackWriter.swift" \
  "$projectRoot/Sources/MacSegmentedManifest.swift" "$projectRoot/Sources/ASRWindowPolicy.swift" "$projectRoot/Sources/TranscriptionEngine.swift" \
  Paragraph.swift "$projectRoot/Tests/CanonicalTranscriptionSmoke.swift" -o canonical-asr-smoke
./canonical-asr-smoke fixtures "$projectRoot/Tests/CanonicalASRWorkerFake.py"
print "Evidence directory: $runDir"
