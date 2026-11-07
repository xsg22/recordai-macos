#!/usr/bin/env python3
"""Fault-injected worker: real canonical IO, no models or network."""
import sys,json,struct,os,re
from pathlib import Path
command=sys.argv[1]
def clips():
    stream=sys.stdin.buffer
    while True:
        prefix=stream.read(4)
        if not prefix:return
        size=struct.unpack('<I',prefix)[0];clip=json.loads(stream.read(size));remaining=clip['frames']*4
        while remaining:
            data=stream.read(min(65536,remaining));assert data;remaining-=len(data)
        yield clip
def read(path):return json.loads(Path(path).read_text())
def save(path,value):Path(path).write_text(json.dumps(value))
def trace(**values):
    with open(os.environ['TALKTUCK_SEAM_CALLS'],'a')as f:f.write(json.dumps(dict(command=command,**values))+'\n')
if command=='--transcribe-stream':
    segments=[]
    for clip in clips():
        trace(start=clip['start'],end=clip['end'])
        text=''.join('word%d '%i for i in range(12)).strip()+'.'
        segments.append(dict(text=text,start=clip['start'],end=clip['end']))
    save(sys.argv[4],dict(segments=segments))
elif command=='--diarize-stream-checkpoint':
    state=Path(sys.argv[4]);old=read(state)if state.exists()else{};length=len(sys.stdin.buffer.read())/4/16000;end=old.get('seconds',0)+length-old.get('skipSeconds',0)
    trace(seconds=end);save(state,dict(version=1,seconds=end));state.with_suffix('.safetensors').write_bytes(b'fixture-state')
    save(sys.argv[3],dict(turns=[dict(start=0,end=length,speaker='0')],batchEnd=end))
elif command=='--align-stream':
    words=[]
    for clip in clips():
        trace(start=clip['start'],end=clip['end'])
        tokens=re.findall(r'\S+\s*',clip['text']);delta=(clip['end']-clip['start'])/len(tokens)
        for i,text in enumerate(tokens):words.append(dict(text=text,separator='',start=clip['start']+i*delta,end=clip['start']+(i+1)*delta))
    save(sys.argv[4],dict(alignedWords=words,paragraphs=[dict(text=''.join(w['text']for w in words),separator='',start=0,end=words[-1]['end'],speakerIDs=['0'])]))
elif command=='--crop-speakers':
    value=read(sys.argv[2]);voice=read(sys.argv[3]);trace(seconds=voice['batchEnd'])
    if voice['batchEnd']==45 and not Path(os.environ['TALKTUCK_SEAM_ALLOW']).exists():raise ValueError('Overlap word timing uncertain')
    words=[w for w in value['alignedWords']if w['end']>float(sys.argv[4])];text=''.join(w['text']for w in words)
    save(sys.argv[6],dict(text=text,paragraphs=[dict(text=text,separator='',start=words[0]['start'],end=words[-1]['end'],speakerIDs=['0'])]))
elif command=='--splice-seam':
    old=read(sys.argv[2]);new=read(sys.argv[3]);count=int(sys.argv[4]);assert ''.join(w['text']for w in old['alignedWords'][:count])==''.join(w['text']for w in new['alignedWords'])
    save(sys.argv[6],dict(alignedWords=new['alignedWords']+old['alignedWords'][count:]))
else:raise ValueError(command)
