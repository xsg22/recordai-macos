#!/usr/bin/env python3
"""Exercise the actual bundled CLI/MCP bootstrap with isolated files, no agent install or capture."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import wave

ROOT = Path(__file__).resolve().parents[1]
(ROOT / '.build').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="agent setup ' ", dir=ROOT / '.build') as scratch:
    scratch = Path(scratch)
    app = scratch / "RecordAI ' Local.app"
    macos = app / 'Contents/MacOS'
    macos.mkdir(parents=True)
    shutil.copytree(ROOT / 'Resources/AgentSkill', app / 'Contents/Resources/AgentSkill')
    shutil.copyfile(ROOT / 'Resources/Info.plist', app / 'Contents/Info.plist')
    cli = macos / 'recordai'
    subprocess.run(['xcrun', 'swiftc', '-warnings-as-errors', '-swift-version', '5', '-target', 'arm64-apple-macosx14.0',
                    'Sources/AgentSchema.swift', 'Sources/RecordAIControl.swift', 'Sources/AgentSetup.swift',
                    'Native/AgentCLI/main.swift', '-o', str(cli)], cwd=ROOT, check=True)
    library = scratch / "Library ' with spaces"
    data_root = library / 'AgentData'

    def run(*args, ok=True):
        p = subprocess.run([str(cli), '--root', str(data_root), *args], text=True, capture_output=True, timeout=15)
        assert (p.returncode == 0) == ok, (args, p.returncode, p.stderr)
        return json.loads(p.stdout) if ok else p

    def mcp(requests):
        p = subprocess.run([str(cli), '--root', str(data_root), 'mcp'], input='\n'.join(map(json.dumps, requests)) + '\n',
                           text=True, capture_output=True, timeout=15, check=True)
        assert not p.stderr
        return {x['id']: x for x in map(json.loads, p.stdout.splitlines())}

    # Bootstrap is usable before any meeting exists and must not create a data directory.
    setup = run('setup', '--json')
    assert not library.exists()
    assert setup['schemaVersion'] == 1
    version = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())['CFBundleShortVersionString']
    assert setup['appVersion'] == version
    assert setup['connection']['cliPath'] == str(cli)
    assert setup['connection']['dataRoot'] == str(data_root)
    files = setup['skill']['files']
    assert files['SKILL.md'] == (ROOT / 'Resources/AgentSkill/recordai/SKILL.md').read_text()
    assert json.loads(files['references/connection.json'])['mcpServer']['args'] == ['--root', str(data_root), 'mcp']
    assert run('list') == [] and run('status')['available'] is False
    r = mcp([{'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-03-26'}},
             {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call', 'params': {'name': 'get_agent_setup'}},
             {'jsonrpc': '2.0', 'id': 3, 'method': 'resources/read', 'params': {'uri': 'recordai://setup'}},
             {'jsonrpc': '2.0', 'id': 4, 'method': 'resources/list'}])
    assert r[1]['result']['serverInfo']['version'] == version
    assert json.loads(r[2]['result']['content'][0]['text']) == setup
    assert json.loads(r[3]['result']['contents'][0]['text']) == setup
    assert r[4]['result']['resources'][0]['uri'] == 'recordai://setup'
    assert not library.exists(), 'Read-only bootstrap created files'

    # Simulate an agent writing the returned skill in an isolated home, never the user's real agent configuration.
    home = scratch / 'Agent Home'
    for relative, content in files.items():
        path = home / '.agents/skills/recordai' / relative
        assert not Path(relative).is_absolute() and '..' not in Path(relative).parts
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
    connection = json.loads((home / '.agents/skills/recordai/references/connection.json').read_text())
    assert subprocess.check_output([connection['cliPath'], '--root', connection['dataRoot'], 'list'], text=True).strip() == '[]'

    id = '11111111-2222-3333-4444-555555555555'
    recording = data_root / 'recordings' / id
    recording.mkdir(parents=True)
    original = library / 'Meetings' / id
    (original / 'Audio').mkdir(parents=True)
    (original / 'meeting.json').write_text('{"notes":"旧笔记","summary":"旧总结"}')
    audio = original / 'Audio/fixture.wav'
    with wave.open(str(audio), 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(bytes(3200))
    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')
    record = dict(schemaVersion=1, id=id, title='中文录音', createdAt=now, updatedAt=now, status='completed',
                  language='zh', duration=.1, revision=1, contentDigest='fixture', transcriptionReady=True,
                  speakerAnalysisStatus='completed', ready=True, finalText='你好，世界！', originalSubtitles='',
                  markdown='## 转录正文\n你好，世界！', paragraphs=[],
                  audioFiles=[dict(part=0, path=str(audio), mime='audio/wav', duration=.1, available=True)],
                  speakers=[], previewIsFinal=False, livePreview='还未定稿', legacyContentAvailable=True)
    (recording / 'record.json').write_text(json.dumps(record))
    (data_root / 'events.json').write_text(json.dumps([dict(sequence=1, id=id, revision=1, kind='updated')]))
    subprocess.run([sys.executable, str(ROOT / 'Tests/AgentCLIIntegration.py'), str(cli), str(library)], check=True)
    assert '旧笔记' not in json.dumps(run('setup', '--json'), ensure_ascii=False)

    # Control uses only the fixture queue; cold-start is rejected for custom roots before invoking macOS open.
    before = hashlib.sha256((original / 'meeting.json').read_bytes()).hexdigest()
    run('control', 'start_recording', '--launch', ok=False)
    assert not (data_root / 'Control').exists()
    run('control', 'unknown', ok=False)
    queued = run('control', 'pause_recording')
    command_id = queued['commandId']
    assert queued['accepted'] and len(list((data_root / 'Control/commands').glob('*.json'))) == 1
    results = data_root / 'Control/results'; results.mkdir(parents=True)
    (results / (command_id + '.json')).write_text(json.dumps({'status': 'rejected', 'result': '当前没有录音'}))
    assert run('result', command_id)['status'] == 'rejected'
    run('result', '../../private', ok=False)
    runtime = dict(schemaVersion=1, observedAt=now, processID=os.getpid(), recording=False, paused=False,
                   preparing=False, busy=False, status='空闲', available=True)
    (data_root / 'runtime.json').write_text(json.dumps(runtime))
    assert run('status')['available'] and not run('status')['recording']
    r = mcp([{'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call', 'params': {'name': 'get_recording_status'}},
             {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call', 'params': {'name': 'get_command_result', 'arguments': {'commandId': command_id}}},
             {'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call', 'params': {'name': 'control_recording', 'arguments': {'action': 'start_recording', 'launch': True}}}])
    assert json.loads(r[1]['result']['content'][0]['text'])['available']
    assert json.loads(r[2]['result']['content'][0]['text'])['status'] == 'rejected'
    assert r[3]['result']['isError']
    runtime['observedAt'] = '2000-01-01T00:00:00Z'
    (data_root / 'runtime.json').write_text(json.dumps(runtime))
    assert run('status')['available'] is False
    assert hashlib.sha256((original / 'meeting.json').read_bytes()).hexdigest() == before
    assert not (home / '.claude').exists()
    print('PASS: bundled CLI/MCP setup equality, no-data read-only bootstrap, version, spaced/quoted paths, isolated skill installation/query, queue/result/status, stale status and cold-start boundaries; no real agent configuration or recording touched.')
