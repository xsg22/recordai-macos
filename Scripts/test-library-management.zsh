#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build
runDir="$(mktemp -d "$PWD/.build/library-management-test.XXXXXX")"
print "$runDir" > .build/library-management-last-run.txt
python3 - "$runDir/AppTypes.swift" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_text(Path('Sources/CoHearTranscribeApp.swift').read_text().replace('@main\n', ''))
names = ['LibrarySmoke', 'AgentDataSmoke', 'SpeakerEditingSmoke', 'ParagraphPlaybackSmoke', 'OrganizationSmoke']
text = '\n'.join(Path('Tests', name + '.swift').read_text().replace('@main\n', '').replace('@main ', '') for name in names)
text += '\n@main struct ManagementRegressions { @MainActor static func main() async throws { try LibrarySmoke.main(); try AgentDataSmoke.main(); try SpeakerEditingSmoke.main(); try await ParagraphPlaybackSmoke.main(); try OrganizationSmoke.main() } }\n'
Path(sys.argv[1]).with_name('Regressions.swift').write_text(text)
PY
sources=(Sources/*.swift)
sources=(${sources:#Sources/CoHearTranscribeApp.swift})
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
    $sources "$runDir/AppTypes.swift" "$runDir/Regressions.swift" -o "$runDir/organization-smoke"
TALKTUCK_TEST_AGENT_OUT="$runDir/agent-fixture" "$runDir/organization-smoke" "$@" | tee "$runDir/domain.log"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
    Sources/AgentSchema.swift Sources/TalkTuckControl.swift Sources/AgentSetup.swift Native/AgentCLI/main.swift -o "$runDir/talktuck"
python3 Tests/OrganizationCLIIntegration.py "$runDir/talktuck" "$runDir/agent-fixture" | tee "$runDir/agent.log"
python3 Tests/SpeakerAttributionSmoke.py | tee "$runDir/fragment.log"
python3 -m unittest discover -s Tests/reporting -v > "$runDir/report.log" 2>&1
print "PASS: 资料管理与 Agent 验证记录 $runDir"
