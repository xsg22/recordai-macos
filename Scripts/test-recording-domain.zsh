#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build
runDir="$(mktemp -d "$PWD/.build/recording-domain-test.XXXXXX")"
python3 - "$runDir/AppTypes.swift" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_text(Path('Sources/CoHearTranscribeApp.swift').read_text().replace('@main\n', ''))
PY
cp -R Sources "$runDir/Sources"
rm "$runDir/Sources/CoHearTranscribeApp.swift"
sources=("$runDir"/Sources/*.swift)
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 $sources "$runDir/AppTypes.swift" Tests/RecordingDomainSmoke.swift -o "$runDir/domain-smoke"
"$runDir/domain-smoke" | tee "$runDir/result.log"
