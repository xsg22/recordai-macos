param(
    [ValidateSet('Contracts', 'Devices', 'Capture', 'Engine')][string]$Mode = 'Contracts',
    [ValidateSet('microphone', 'system', 'both')][string]$Source = 'system',
    [ValidateSet('faster-whisper', 'qwen')][string]$Engine = 'faster-whisper',
    [ValidateSet('zh', 'en', 'auto')][string]$Language = 'auto',
    [ValidateSet('cpu', 'cuda')][string]$Device = 'cpu',
    [string]$Model, [string]$Audio, [string]$Reference,
    [ValidateRange(1, 120)][int]$Seconds = 10,
    [string]$Output = (Join-Path $PWD ('TalkTuck-validation-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))),
    [switch]$AllowModelDownload
)
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitOperatingSystem) { throw 'Use Windows x64 and Python 3.12 x64.' }
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$venv = Join-Path $repo '.tools/windows-probe'
if (-not (Test-Path (Join-Path $venv 'Scripts/python.exe'))) {
    & py -3.12 -m venv $venv
    if ($LASTEXITCODE -ne 0) { throw 'Install Python 3.12 x64, including the py launcher.' }
}
$python = Join-Path $venv 'Scripts/python.exe'
& $python -c "import sys,struct; assert sys.version_info[:2] == (3,12) and struct.calcsize('P') == 8, 'Python 3.12 x64 is required'"
if ($LASTEXITCODE -ne 0) { throw 'Recreate the probe environment with Python 3.12 x64.' }
New-Item -ItemType Directory -Force -Path $Output | Out-Null
$env:PYTHONUTF8 = '1'
if ($Mode -eq 'Contracts') {
    & $python -m unittest discover -s (Join-Path $repo 'Tests/windows') -v
    exit $LASTEXITCODE
}
if ($Mode -in @('Devices', 'Capture')) {
    & $python -m pip install -r (Join-Path $PSScriptRoot 'requirements-capture.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Capture dependencies could not be installed.' }
    $probeArgs = @((Join-Path $PSScriptRoot 'talktuck_probe.py'), 'devices', '--output', (Join-Path $Output 'devices.json'))
    if ($Mode -eq 'Capture') {
        $probeArgs = @((Join-Path $PSScriptRoot 'talktuck_probe.py'), 'capture', '--source', $Source, '--seconds', $Seconds, '--output', (Join-Path $Output 'capture.json'))
    }
} else {
    if (-not $Model -or -not $Audio) { throw 'Engine validation requires -Model and -Audio.' }
    $requirements = if ($Engine -eq 'qwen') { 'requirements-qwen.txt' } else { 'requirements-whisper.txt' }
    & $python -m pip install -r (Join-Path $PSScriptRoot $requirements)
    if ($LASTEXITCODE -ne 0) { throw 'Engine dependencies could not be installed.' }
    $probeArgs = @((Join-Path $PSScriptRoot 'talktuck_probe.py'), 'transcribe', '--engine', $Engine, '--model', $Model, '--input', $Audio, '--language', $Language, '--device', $Device, '--output', (Join-Path $Output 'engine.json'))
    if ($Reference) { $probeArgs += @('--reference', $Reference) }
    if ($AllowModelDownload) { $probeArgs += '--allow-download' }
}
& $python @probeArgs
exit $LASTEXITCODE
