"""Run existing account, authorization and assistant contracts with isolated fixtures."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / '.build'
BUILD.mkdir(exist_ok=True)
tests = [
    ('BrowserAuthorizationSmoke', True), ('NotionConnectionSmoke', False),
    ('DingTalkNotificationSmoke', False), ('DingTalkSyncStagesSmoke', True),
    ('FeishuAuthorizationRecoverySmoke', True), ('OptionalModelSmoke', True),
    ('OptionalModelFallbackSmoke', True), ('IntelligenceSmoke', True),
]
sources = sorted(str(p) for p in (ROOT / 'Sources').glob('*.swift') if p.name != 'CoHearTranscribeApp.swift')
app_types = BUILD / 'UIContractAppTypes.swift'
app_types.write_text((ROOT / 'Sources/CoHearTranscribeApp.swift').read_text().replace('@main\n', ''))
runner = BUILD / 'UIContractRegression.swift'
parts = [(ROOT / 'Tests' / (name + '.swift')).read_text().replace('@main', '') for name, _ in tests]
parts.append('@main struct UIContractRegression { @MainActor static func main() async throws { ' + '; '.join(
    ('try await ' if asynchronous else 'try ') + name + '.main()' for name, asynchronous in tests
) + ' } }')
runner.write_text('\n'.join(parts))
executable = BUILD / 'ui-contract-regression'
subprocess.run(['xcrun', 'swiftc', '-warnings-as-errors', '-swift-version', '5', '-parse-as-library',
                '-target', 'arm64-apple-macosx14.0', *sources, str(app_types), str(runner), '-o', str(executable)], check=True)
subprocess.run([str(executable)], check=True)
