#!/usr/bin/python3
import json,pathlib,sys,wave,os
if sys.argv[1]=='--diarize':
 pathlib.Path(sys.argv[4]).write_text(json.dumps({'turns':[]}))
 if os.environ.get('TALKTUCK_TEST_DIARIZE_TRACE'):pathlib.Path(os.environ['TALKTUCK_TEST_DIARIZE_TRACE']).write_text('completed')
elif sys.argv[1]=='--align-speakers':
 clips=json.loads(pathlib.Path(sys.argv[3]).read_text()); rows=[]
 for i,c in enumerate(clips):
  with wave.open(c['audio']) as w:
   assert (w.getnchannels(),w.getframerate(),w.getsampwidth()) == (1,16000,2)
   assert w.getnframes()>0
  if os.environ.get('TALKTUCK_TEST_ZERO_TIME'):
   rows.extend([dict(text=c['text'][:2],separator='',start=c['start'],end=c['start']+.5,speakerIDs=['0']),dict(text=c['text'][2:],separator='',start=c['start']+.5,end=c['start']+.5,speakerIDs=['0'])])
  else:rows.append(dict(text=c['text'],separator='' if i==0 else '\n',start=c['start'],end=c['end'],speakerIDs=['0']))
 pathlib.Path(sys.argv[5]).write_text(json.dumps({'paragraphs':rows},ensure_ascii=False))
else:raise ValueError('unexpected mode')
