#!/usr/bin/python3
import json,os,pathlib,struct,sys
assert sys.argv[1]=='--transcribe-stream'
hints=json.loads(pathlib.Path(sys.argv[5]).read_text())
assert hints['words']==['Codex','TalkTuck','TestName']
clips=[]
while True:
 size=sys.stdin.buffer.read(4)
 if not size:break
 c=json.loads(sys.stdin.buffer.read(struct.unpack('<I',size)[0]));data=sys.stdin.buffer.read(c['frames']*4)
 assert len(data)==c['frames']*4;clips.append(c)
assert len(clips)==1 and clips[0]['frames']==38*16000
pathlib.Path(os.environ['TALKTUCK_CACHE_TEST_TRACE']).write_text(json.dumps({'frames':clips[0]['frames'],'hotwords':hints['words'],'output':sys.argv[4]}))
pathlib.Path(sys.argv[4]).write_text(json.dumps({'segments':[dict(text='TestName uses Codex to build TalkTuck.',start=0,end=38)]}))
