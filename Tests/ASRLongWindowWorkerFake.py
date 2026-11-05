#!/usr/bin/python3
import json,os,pathlib,struct,sys,wave

def clips():
    while True:
        prefix=sys.stdin.buffer.read(4)
        if not prefix:return
        size=struct.unpack('<I',prefix)[0];header=json.loads(sys.stdin.buffer.read(size))
        data=sys.stdin.buffer.read(header['frames']*4)
        assert len(data)==header['frames']*4
        assert abs(header['frames']-(header['end']-header['start'])*16000)<1
        yield header
if sys.argv[1]=='--transcribe-stream':
    rows=list(clips());expected=int(os.environ.get('EXPECTED_WINDOW','120'))
    assert all(0<r['end']-r['start']<=expected for r in rows)
    assert rows[0]['start']==0 and rows[-1]['end']==130
    pathlib.Path(sys.argv[4]).write_text(json.dumps({'segments':[dict(text='片段'+str(i),start=r['start'],end=r['end']) for i,r in enumerate(rows)]}))
elif sys.argv[1]=='--diarize':
    pathlib.Path(sys.argv[4]).write_text('{"turns":[]}')
elif sys.argv[1]=='--align-speakers':
    rows=[]
    for i,r in enumerate(json.loads(pathlib.Path(sys.argv[3]).read_text())):
        with wave.open(r['audio']) as f:assert abs(f.getnframes()/16000-(r['end']-r['start']))<.001
        rows.append(dict(text=r['text'],separator='' if i==0 else '\n',start=r['start'],end=r['end'],speakerIDs=['0']))
    pathlib.Path(sys.argv[5]).write_text(json.dumps({'paragraphs':rows}))
else:raise ValueError('Unexpected invocation')
