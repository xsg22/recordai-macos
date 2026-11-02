#!/usr/bin/env python3
"""Real macOS engine acceptance with local synthetic speech; never records a microphone."""
import argparse
import array
import hashlib
import json
from pathlib import Path
import platform
import struct
import subprocess
import tempfile
import wave

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--engine-dir', type=Path, required=True, help='Current built ASR folder containing qwen-asr, paraformer-live, dylibs and _internal')
parser.add_argument('--model-root', type=Path, required=True, help='Read-only installed ASR model root')
args = parser.parse_args()
if platform.system() != 'Darwin': parser.error('This harness requires macOS say/afconvert. Windows has its own probe.')
engine, models = args.engine_dir.resolve(), args.model_root.resolve()
for path in [engine/'qwen-asr', engine/'paraformer-live', models/'Qwen3ASR', models/'Paraformer']:
    if not path.exists(): parser.error('Missing prerequisite: ' + str(path))
scratch = Path(tempfile.mkdtemp(prefix='bilingual-engine-', dir=ROOT/'.build'))
sentences = [('english-a', 'Samantha', 'Welcome to the Record AI test. Please keep the original recording and organize it into a group. The next release is version zero point one seven.'),
             ('english-b', 'Daniel', 'I will check offline transcription on Friday. The budget is twenty five dollars. Let the external agent read the final transcript.'),
             ('chinese', 'Tingting', '大家好，今天测试离线转录。请保留原始录音，按照分组管理资料。让外部智能助手读取转录结果。')]
for name, voice, text in sentences:
    subprocess.run(['say','-v',voice,'-r','155','-o',str(scratch/(name+'.aiff')),text],check=True)
    subprocess.run(['afconvert','-f','WAVE','-d','LEI16@16000','-c','1',str(scratch/(name+'.aiff')),str(scratch/(name+'.wav'))],check=True)

def combine(name, parts):
    path = scratch/(name+'.wav')
    with wave.open(str(path),'wb') as target:
        target.setnchannels(1); target.setsampwidth(2); target.setframerate(16000)
        for part in parts:
            with wave.open(str(scratch/(part+'.wav')),'rb') as source:
                assert (source.getnchannels(),source.getsampwidth(),source.getframerate()) == (1,2,16000)
                target.writeframes(source.readframes(source.getnframes())); target.writeframes(bytes(32000))
    return path

english = combine('english',['english-a','english-b'])
mixed = combine('mixed',['english-a','chinese','english-b'])
subprocess.run(['zsh','Scripts/test-localization.zsh'],cwd=ROOT,check=True)
runner = ROOT/'.build/LocalizationTests.app/Contents/MacOS/test'
for language, audio in [('en',english),('auto',mixed)]:
    before = hashlib.sha256(audio.read_bytes()).hexdigest()
    subprocess.run([str(runner),str(engine/'qwen-asr'),str(models/'Qwen3ASR'),str(audio),language,str(scratch/(language+'-result'))],check=True)
    assert hashlib.sha256(audio.read_bytes()).hexdigest() == before

with wave.open(str(english),'rb') as source:
    samples = array.array('h',source.readframes(source.getnframes()))
frames = []
for offset in range(0,len(samples),1600):
    block = samples[offset:offset+1600]
    frames.append(struct.pack('<I',len(block))+struct.pack('<'+'f'*len(block),*[value/32768 for value in block]))
live = subprocess.run([str(engine/'paraformer-live'),str(models/'Paraformer'),'en'],input=b''.join(frames),capture_output=True,timeout=120)
(scratch/'live-en.jsonl').write_bytes(live.stdout); (scratch/'live-en.stderr').write_bytes(live.stderr)
assert live.returncode == 0, live.stderr.decode(errors='replace')
events = [json.loads(line) for line in live.stdout.decode().splitlines()]
assert any(e.get('effectiveLanguage') == 'zh-en' and e.get('forcedLanguage') is False for e in events)
assert any(e.get('type') == 'commit' and any(c.isascii() and c.isalpha() for c in e.get('text','')) for e in events)
print('PASS: real English live PCM decode, final English + mixed transcription, speaker alignment and input preservation. Evidence:',scratch)
