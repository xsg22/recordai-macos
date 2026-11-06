#!/usr/bin/python3
import json,pathlib,struct,sys,wave,os

def clips():
 while True:
  n=sys.stdin.buffer.read(4)
  if not n:return
  if len(n)!=4:raise ValueError('truncated metadata')
  c=json.loads(sys.stdin.buffer.read(struct.unpack('<I',n)[0]));data=sys.stdin.buffer.read(c['frames']*4)
  assert len(data)==c['frames']*4
  yield c,data
if sys.argv[1]=='--transcribe-stream':
 out=[]
 for index,(c,_) in enumerate(clips()):
  assert 300<c['end']-c['start']<=480
  a,b=('Alice reviewed the design. ','Bob will implement it, tomorrow.') if index==0 else ('Bob will implement it, tomorrow. ','Carol will verify it.')
  text=a+b;mid=(c['start']+c['end'])/2
  p=[dict(text=a,start=c['start'],end=mid+2),dict(text=b,start=mid-2,end=c['end'])]
  if os.environ.get('BAD_ALIGNMENT_PARTS')=='1':p[1]['text']='BAD'
  row=dict(text=text,start=c['start'],end=c['end'])
  if os.environ.get('NO_ALIGNMENT_PARTS')!='1':row['alignmentParts']=p
  out.append(row)
 pathlib.Path(sys.argv[4]).write_text(json.dumps(dict(segments=out)))
elif sys.argv[1]=='--diarize':pathlib.Path(sys.argv[4]).write_text('{"turns":[]}')
elif sys.argv[1]=='--align-speakers':
 rows=[]
 for c in json.loads(pathlib.Path(sys.argv[3]).read_text()):
  with wave.open(c['audio']) as f:assert 0<f.getnframes()<=300*16000
  rows.append(dict(text=c['text'],separator=c.get('separator',''),start=c['start'],end=c['end'],speakerIDs=['0']))
 if os.environ.get('BAD_ALIGNMENT_ORDER')=='1':rows[-1]['start']=1
 pathlib.Path(sys.argv[5]).write_text(json.dumps(dict(paragraphs=rows)))
else:raise ValueError('unexpected mode')
