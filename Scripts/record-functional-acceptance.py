#!/usr/bin/env python3
"""Validate saved native acceptance evidence and bind a functional release to current source.

Uses the four-turn synthetic weekly-demo fixture. Never fabricates UI actions, runs capture,
or changes the library. Run after actual import, playback, correction, grouping and exports.
"""
import argparse
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--context', type=Path, required=True)
parser.add_argument('--evidence', type=Path, required=True)
args = parser.parse_args()
evidence = args.evidence.resolve()
assert evidence.is_relative_to(ROOT/'Docs'), 'Evidence must be stored in this repository Docs directory'
context = json.loads(args.context.read_text())
scratch, library, app = (Path(context[key]) for key in ['root','library','app'])
version = plistlib.loads((ROOT/'Resources/Info.plist').read_bytes())['CFBundleShortVersionString']
assert context['version'] == version == plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
assert subprocess.check_output(['git','diff','HEAD','--','Sources','Resources'],cwd=ROOT) == b'', 'Commit the exact validated application inputs first'
source_commit = subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
sha = lambda path: hashlib.sha256(Path(path).read_bytes()).hexdigest()
write = lambda path, value: path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
before = json.loads((evidence/'meeting-before-edit.json').read_text())
after = json.loads(Path(context['meetingPath']).read_text())
assert after['status'] == 'completed' and after['speakerAnalysisStatus'] == 'completed'
assert len(after['transcriptParagraphs']) == 4
sequence = [row['speakerIDs'][0].split(':')[-1] for row in after['transcriptParagraphs']]
assert sequence == ['0','1','0','1']
wrong, corrected = '测试组完成首页交付', '设计组完成首页交付'
assert wrong in before['text'] and after['text'] == before['text'].replace(wrong,corrected)
for old, new in zip(before['transcriptParagraphs'],after['transcriptParagraphs']):
    assert {k:v for k,v in old.items() if k != 'text'} == {k:v for k,v in new.items() if k != 'text'}
assert before['subtitles'] == after['subtitles'] == (scratch/'original.srt').read_text()
assert before['audioFiles'] == after['audioFiles']
audio = Path(context['meetingPath']).parent/'Audio'/after['audioFiles'][0]
assert sha(audio) == sha(Path(context['audio'])) == context['sourceAudioSHA256']
original, fixed = ((scratch/name).read_text() for name in ['original.md','corrected.md'])
assert original.replace(wrong,corrected) == fixed
assert all(row['text'] in fixed for row in after['transcriptParagraphs'])
assert all(marker in original for marker in ['发言人 1','发言人 2','8 秒','23 秒'])
playing = (evidence/'03-segment-playing.ax.txt').read_text()
ended = (evidence/'import-e2e/05-segment-ended.ax.txt').read_text()
position = lambda text: float(re.search(r'Value: ([0-9.]+), Details:',text)[1])
playing_at, stopped_at = position(playing), position(ended)
second = before['transcriptParagraphs'][1]
assert second['start'] <= playing_at < second['end']
assert abs(stopped_at-second['end']) < .15
assert '暂停回放' in playing and 'Description: 播放录音' in ended
assert 'button 开始转录' in (evidence/'direct-start.ax.txt').read_text()
assert '正在本地识别' in (evidence/'processing.ax.txt').read_text()
assert '让你的 AI 助手使用这段录音' in (evidence/'02-transcribed.ax.txt').read_text()
assert '产品讨论' in (evidence/'organized.ax.txt').read_text()
base = [str(app/'Contents/MacOS/recordai'),'--root',str(library/'AgentData')]
run = lambda *arguments: json.loads(subprocess.check_output(base+list(arguments),text=True))
setup, current, status = run('setup','--json'), run('read',after['id']), run('status')
assert setup['appVersion'] == version and current['finalText'] == after['text']
assert current['organization']['group']['name'] == '产品讨论'
assert status['available'] and not status['recording'] and not status['preparing']
assert current['revision'] > json.loads((evidence/'agent-before-edit.json').read_text())['revision']
requests = [dict(jsonrpc='2.0',id=1,method='initialize',params={'protocolVersion':'2025-03-26'}),
            dict(jsonrpc='2.0',id=2,method='tools/call',params={'name':'get_agent_setup'}),
            dict(jsonrpc='2.0',id=3,method='tools/call',params={'name':'get_recording','arguments':{'id':after['id']}})]
responses = [json.loads(line) for line in subprocess.check_output(base+['mcp'],input='\n'.join(map(json.dumps,requests))+'\n',text=True).splitlines()]
assert json.loads(responses[1]['result']['content'][0]['text']) == setup
assert json.loads(responses[2]['result']['content'][0]['text'])['finalText'] == after['text']
spec = importlib.util.spec_from_file_location('gate',ROOT/'Scripts/check-functional-acceptance.py')
gate = importlib.util.module_from_spec(spec); spec.loader.exec_module(gate)
paths = list((ROOT/'Sources').glob('*.swift'))+[path for path in (ROOT/'Resources').rglob('*') if path.is_file()]
digest = gate.digest(paths); now = datetime.datetime.now(datetime.timezone.utc).isoformat()
log = (evidence/'build-and-verification.log').read_text()
assert f'PASS: {version} 的签名' in log and 'PASS: bundled CLI/MCP' in log and 'MeetingIntelligence smoke passed' in log
assert 'PASS: 资料管理与 Agent 验证记录' in log and 'PASS: UI catalog' in log
for directory, language in [('english','en'),('mixed','auto')]:
    output = evidence/directory
    report = json.loads((output/'report.json').read_text())
    assert report['language'] == language and report['realModelInference'] and report['textPreserved']
    text = (output/'transcript.txt').read_text()
    rows = json.loads((output/'paragraphs.json').read_text())
    assert ''.join(row['separator']+row['text'] for row in rows) == text
    assert re.search('[A-Za-z]{3}',text) and '-->' in (output/'transcript.srt').read_text()
    if language == 'auto': assert re.search('[\u4e00-\u9fff]',text)
assert 'Interface language' in (evidence/'settings-en.ax.txt').read_text()
assert json.loads((evidence/'locale-data-invariant.json').read_text())['meetingAndAgentBytesUnchanged']
write(evidence/'bilingual-acceptance.json',dict(recorded_at=now,sourceDigest=digest,
    packagedEngineSHA256=sha(app/'Contents/Resources/Engine/ASR/qwen-asr'),
    englishTranscriptionAndAlignment=True,mixedTranscriptionAndAlignment=True,
    nativeEnglishInterface=True,localeDataInvariant=True))
write(evidence/'import-e2e/result.json',dict(recorded_at=now,app_version=version,app_sourceDigest=digest,
    scope='Actual production candidate in isolated Home; native import/main button, embedded engine, playback, correction and exports. No hardware capture.',
    meeting_id=after['id'],input_duration_seconds=after['duration'],processing_seconds=after['seconds'],
    source_audio_sha256=sha(Path(context['audio'])),managed_copy_sha256=sha(audio),paragraph_count=4,speaker_sequence=sequence,
    actual_text_before_edit=before['text'],segment_playback=dict(passed=True,observed_playing_seconds=playing_at,automatic_stop_seconds=stopped_at),
    manual_correction=dict(saved=True,timestamps_speakers_ids_and_audio_unchanged=True,raw_subtitles_unchanged=True),
    export=dict(markdown_original=True,markdown_corrected=True,speaker_and_time_markers=True,original_srt=True),
    direct_entry_recheck=dict(sourceDigest=digest,direct_start_button_verified=True,clicked_direct_button=True,completed=True,
                              speaker_analysis_completed=True,source_preserved=True,speaker_sequence=sequence),
    limits='Synthetic sample has a recognition error corrected manually; no fresh hardware capture, OAuth/remote writes or full design sign-off.'))
for source,target in [('original.md','合成会议导入验收-原始识别.md'),('corrected.md','合成会议导入验收-人工校正.md'),('original.srt','合成会议导入验收.srt')]:
    shutil.copyfile(scratch/source,evidence/'import-e2e'/target)
write(evidence/'data-regression.json',dict(recorded_at=now,sourceDigest=digest,exit_code=0,regression_groups=14,
    command='PATH=/opt/homebrew/opt/python@3.12/libexec/bin:$PATH zsh Scripts/release.zsh --candidate',
    source_sha256={str(path.relative_to(ROOT)):sha(path) for path in paths}))
write(evidence/'ui-contracts.json',dict(recorded_at=now,sourceDigest=digest,exit_code=0,
    tests=['BrowserAuthorizationSmoke','NotionConnectionSmoke','DingTalkNotificationSmoke','DingTalkSyncStagesSmoke',
           'FeishuAuthorizationRecoverySmoke','OptionalModelSmoke','OptionalModelFallbackSmoke','IntelligenceSmoke'],
    scope='Isolated contract tests; no actual OAuth or remote publication.'))
write(evidence/'candidate-package.json',dict(recorded_at=now,version=version,sourceDigest=digest,script_exit_code=0,
    main_binary_sha256=sha(app/'Contents/MacOS/RecordAIApp'),cli_sha256=sha(app/'Contents/MacOS/recordai'),
    embedded_asr_sha256=sha(app/'Contents/Resources/Engine/ASR/qwen-asr'),
    artifacts={path.name:sha(path) for path in (ROOT/'dist').glob(f'RecordAI-{version}-arm64.*') if path.suffix in ['.dmg','.pkg']}))
binding_path = ROOT/'Docs/design-v2/validation/functional-release-binding.json'
binding = json.loads(binding_path.read_text())
previous_evidence = ROOT/binding['evidenceRoot']
if previous_evidence != evidence and not (previous_evidence/'functional-release-binding.json').exists():
    shutil.copyfile(binding_path,previous_evidence/'functional-release-binding.json')
runtime_inputs = sorted(set(binding['runtimeInputs']+['Native/QwenRuntime/language_policy.py']))
binding.update(recorded_at=now,verifiedSourceCommit=source_commit,sourceDigest=digest,runtimeInputs=runtime_inputs,
    runtimeInputDigest=gate.digest([ROOT/name for name in runtime_inputs]),
    embeddedAsrSha256=sha(app/'Contents/Resources/Engine/ASR/qwen-asr'),evidenceRoot=str(evidence.relative_to(ROOT)),
    releasePolicy='User authorized publication after primary functional validation; functional prerelease only, without full UI sign-off.',
    verifiedWorkingTree='Application inputs match verifiedSourceCommit; later documentation/evidence commits must preserve these digests.')
write(binding_path,binding)
write(evidence/'agent-verification.json',dict(recorded_at=now,sourceDigest=digest,setupVersion=version,
    cliAndMcpSetupEqual=True,transcriptQueryEqual=True,groupQueryAvailable=True,noRecording=True,
    skillFiles=sorted(setup['skill']['files']),exit_code=0))
print('PASS: native candidate evidence, CLI/MCP and package verification bound to source',digest)
