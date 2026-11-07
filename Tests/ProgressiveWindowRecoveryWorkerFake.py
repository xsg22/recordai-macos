#!/usr/bin/env python3
import sys,json,struct,os
from pathlib import Path
assert sys.argv[1]=='--transcribe-stream'
output=Path(sys.argv[4]);stream=sys.stdin.buffer;segments=[]
while True:
 prefix=stream.read(4)
 if not prefix:break
 size=struct.unpack('<I',prefix)[0];clip=json.loads(stream.read(size));remaining=clip['frames']*4
 while remaining:
  value=stream.read(min(65536,remaining));assert value;remaining-=len(value)
 with open(os.environ['TALKTUCK_RECOVERY_CALLS'],'a')as f:f.write(json.dumps(clip)+'\n')
 if clip['end']-clip['start']>120.001:
  print('Transcript token limit reached; partial result not saved',file=sys.stderr);sys.exit(1)
 segments.append(dict(text='Audio range %s to %s.'%(clip['start'],clip['end']),start=clip['start'],end=clip['end']))
output.write_text(json.dumps(dict(segments=segments)))
