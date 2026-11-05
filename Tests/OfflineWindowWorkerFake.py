#!/usr/bin/python3
"""Deterministic child processes for the production canonical ASR path."""
import json, os, pathlib, struct, sys, time

def exact(n):
    data=sys.stdin.buffer.read(n)
    if len(data)!=n: raise ValueError('truncated input')
    return data

def clips():
    while True:
        prefix=sys.stdin.buffer.read(4)
        if not prefix: return
        if len(prefix)!=4: raise ValueError('truncated header')
        header=json.loads(exact(struct.unpack('<I',prefix)[0]))
        pcm=exact(header['frames']*4)
        if header['frames']<=0 or len(pcm)!=header['frames']*4: raise ValueError('invalid PCM')
        yield header,pcm

args=sys.argv
if pathlib.Path(args[0]).name=='paraformer-live':
    if args[1]!='segment-timestamps': raise ValueError('wrong VAD mode')
    data=sys.stdin.buffer.read()
    if len(data) not in (4*16000*4,5*16000*4): raise ValueError('incorrect source duration')
    first=abs(struct.unpack_from('<f',data,8000*4)[0]); second=abs(struct.unpack_from('<f',data,24000*4)[0])
    if len(data)==5*16000*4:
        if not (first>0.05 and second>first+0.02): raise ValueError('dual-source timeline was not mixed correctly')
    elif not (first>0.1 and second>0.1 and abs(first-second)<0.03): raise ValueError('range offset did not begin in both sources')
    pathlib.Path(args[3]).write_text(json.dumps([] if os.environ.get('CANONICAL_VAD_EMPTY')=='1' else [{'start':0.0,'end':1.0},{'start':1.0,'end':2.0}]))
elif args[1]=='--transcribe-stream' and os.environ.get('WINDOW_TEST')=='1':
    result=[]
    for clip,pcm in clips():
        if not 0 < clip['frames'] <= 384000: raise ValueError('invalid window length')
        result.append(dict(text='测试内容',start=clip['start'],end=clip['end']))
    if [(x['start'],x['end']) for x in result] != [(0,24),(21,45),(42,48)]: raise ValueError('incorrect overlap windows')
    pathlib.Path(args[4]).write_text(json.dumps({'segments':result},ensure_ascii=False))
elif args[1]=='--transcribe-stream':
    hints=json.loads(pathlib.Path(args[5]).read_text())
    if hints['words']!=['产品'] or hints['context'] not in ('产品背景','SLOW_TEST'): raise ValueError('hotwords/context lost')
    if hints['context']=='SLOW_TEST': time.sleep(10)
    result=[]
    for index,(clip,pcm) in enumerate(clips()):
        if clip['frames']!=16000: raise ValueError('wrong clip duration')
        result.append(dict(text=['你好','世界'][index],start=clip['start'],end=clip['end']))
    pathlib.Path(args[4]).write_text(json.dumps({'segments':result},ensure_ascii=False))
elif args[1]=='--diarize-stream':
    data=sys.stdin.buffer.read()
    if len(data) not in (4*16000*4,5*16000*4): raise ValueError('wrong diarization duration')
    pathlib.Path(args[3]).write_text(json.dumps({'turns':[{'start':0,'end':2,'speaker':'0'}]}))
elif args[1]=='--align-stream':
    rows=[]
    for index,(clip,pcm) in enumerate(clips()):
        if clip['language']!='zh' or clip['frames']!=16000: raise ValueError('alignment mismatch')
        rows.append(dict(text=clip['text'],separator='' if index==0 else '\n',start=clip['start'],end=clip['end'],speakerIDs=['0']))
    pathlib.Path(args[4]).write_text(json.dumps({'paragraphs':rows},ensure_ascii=False))
else: raise ValueError('unexpected command')
