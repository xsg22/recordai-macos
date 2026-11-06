#!/usr/bin/python3
import json,os,pathlib,struct,sys
assert sys.argv[1]=='--transcribe-stream' and sys.argv[3]=='en'
rows=[]
while True:
 size=sys.stdin.buffer.read(4)
 if not size:break
 meta=json.loads(sys.stdin.buffer.read(struct.unpack('<I',size)[0]))
 data=sys.stdin.buffer.read(meta['frames']*4)
 assert len(data)==meta['frames']*4
 rows.append(meta)
assert len(rows)==1 and rows[0]['frames']==38*16000
pathlib.Path(os.environ['TALKTUCK_LIVE_TEST_TRACE']).write_text(json.dumps(rows))
pathlib.Path(sys.argv[4]).write_text(json.dumps({'segments':[dict(text='This is the first complete English sentence. This is the second complete English sentence.',start=0,end=38)]}))
