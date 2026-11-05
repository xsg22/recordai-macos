#!/usr/bin/python3
import json,pathlib,sys,wave
if sys.argv[1]=='--diarize':pathlib.Path(sys.argv[4]).write_text(json.dumps({'turns':[]}))
elif sys.argv[1]=='--align-speakers':
 clips=json.loads(pathlib.Path(sys.argv[3]).read_text()); rows=[]
 for i,c in enumerate(clips):
  with wave.open(c['audio']) as w:
   assert (w.getnchannels(),w.getframerate(),w.getsampwidth()) == (1,16000,2)
   assert w.getnframes()>0
  rows.append(dict(text=c['text'],separator='' if i==0 else '\n',start=c['start'],end=c['end'],speakerIDs=['0']))
 pathlib.Path(sys.argv[5]).write_text(json.dumps({'paragraphs':rows},ensure_ascii=False))
else:raise ValueError('unexpected mode')
