#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app="$PWD/.build/LocalizationTests.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
ditto Resources/Localization "$app/Contents/Resources/Localization"
python3 - <<'PY'
from pathlib import Path
import plistlib
Path('.build/LocalizationAppTypes.swift').write_text(Path('Sources/CoHearTranscribeApp.swift').read_text().replace('@main\n', ''))
Path('.build/LocalizationTests.app/Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='com.talktuck.tests.localization', CFBundleExecutable='test')))
PY
sources=(Sources/*.swift)
sources=(${sources:#Sources/CoHearTranscribeApp.swift})
xcrun swiftc -warnings-as-errors -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
    $sources .build/LocalizationAppTypes.swift Tests/LocalizationSmoke.swift -o "$app/Contents/MacOS/test"
"$app/Contents/MacOS/test" "$@"
