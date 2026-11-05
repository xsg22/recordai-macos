#!/usr/bin/env python3
"""Launch the production client with isolated recording data for native UI acceptance.

CFFIXED_USER_HOME does not isolate macOS Keychain. Existing accounts can remain visible;
never publish account pages or credentials without separately checking their contents.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--audio', type=Path, required=True, help='Known shareable synthetic fixture, not a private recording')
parser.add_argument('--models', type=Path, required=True)
parser.add_argument('--context', type=Path, required=True)
args = parser.parse_args()
if args.context.exists(): parser.error('Choose a new context path; prior acceptance evidence is preserved.')
app = args.app.resolve(strict=True)
info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
if info['CFBundleIdentifier'] != 'com.xsg.talktuck': parser.error('Use the actual production candidate bundle.')
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
scratch = Path(tempfile.mkdtemp(prefix='recordai-release-'+info['CFBundleShortVersionString']+'-'))
home = scratch/'Home'; library = home/'Library/Application Support/CoHearTranscribe'
library.mkdir(parents=True)
# APFS clone shares existing model blocks but isolates any verification metadata writes.
subprocess.run(['cp','-cR',str(args.models.resolve(strict=True)),str(library/'Models')],check=True)
audio = scratch/'Product-weekly-demo.wav'; shutil.copyfile(args.audio.resolve(strict=True),audio)
environment = dict(os.environ, CFFIXED_USER_HOME=str(home), RECORD_AI_UI_LANGUAGE='zh-Hans')
with (scratch/'app.log').open('wb') as log:
    process = subprocess.Popen([str(app/'Contents/MacOS/RecordAIApp')],env=environment,stdin=subprocess.DEVNULL,
                               stdout=log,stderr=log,start_new_session=True)
value = dict(root=str(scratch),home=str(home),library=str(library),app=str(app),pid=process.pid,
             version=info['CFBundleShortVersionString'],audio=str(audio),
             sourceAudioSHA256=hashlib.sha256(audio.read_bytes()).hexdigest())
args.context.parent.mkdir(parents=True,exist_ok=True)
args.context.write_text(json.dumps(value,indent=2)+'\n',encoding='utf-8')
print(json.dumps(value,indent=2))
print('Launched only. Import/click/recognition/playback/edit/export still require actual UI verification.')
