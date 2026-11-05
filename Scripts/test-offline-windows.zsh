#!/bin/zsh
set -euo pipefail
projectRoot="${0:A:h:h}"
testRoot="${RECORD_AI_TEST_ROOT:?Set RECORD_AI_TEST_ROOT to an existing writable test directory}"
[[ -d "$testRoot" && -w "$testRoot" ]]
runDir="$(mktemp -d "${testRoot%/}/offline-windows.XXXXXX")"
mkdir -p "$runDir"/{tmp,cache,canonical,alignment}
python3 - "$projectRoot/Sources/TranscriptDocument.swift" "$runDir/Paragraph.swift" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
Path(sys.argv[2]).write_text(s[:s.index('struct LiveUtterance')]+s[s.index('struct TranscriptReadingGroup'):])
PY
cd "$runDir"
export TMPDIR=tmp PYTHONDONTWRITEBYTECODE=1
common=("$projectRoot/Sources/BalancedWatchSync.swift" "$projectRoot/Sources/CanonicalAudioReader.swift" "$projectRoot/Sources/CanonicalAudioInput.swift" "$projectRoot/Sources/TranscriptionEngine.swift" Paragraph.swift)
xcrun swiftc -module-cache-path cache -swift-version 5 -parse-as-library $common "$projectRoot/Tests/OfflineWindowSmoke.swift" -o window-smoke
./window-smoke "$runDir/tmp"
xcrun swiftc -module-cache-path cache -swift-version 5 -parse-as-library "$projectRoot/Sources/ResilientRecordingJournal.swift" $common "$projectRoot/Sources/MacSegmentedTrackWriter.swift" "$projectRoot/Sources/MacSegmentedManifest.swift" "$projectRoot/Tests/CanonicalOfflineWindowSmoke.swift" -o canonical-window-smoke
./canonical-window-smoke "$runDir/canonical" "$projectRoot/Tests/OfflineWindowWorkerFake.py"
xcrun swiftc -module-cache-path cache -swift-version 5 -parse-as-library $common "$projectRoot/Tests/OfflineWindowSpeakerSmoke.swift" -o alignment-smoke
./alignment-smoke "$runDir/alignment" "$projectRoot/Tests/OfflineWindowSpeakerWorkerFake.py"
print "Evidence directory: $runDir"
