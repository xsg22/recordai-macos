#!/usr/bin/env python3
"""Local model benchmark on an explicit, read-only human-reference corpus.

Each invocation isolates one case/window in a process. Does not access the app,
accounts, microphone or library. Output is atomic and existing results rejected.
Requires the application's pinned MLX environment plus rapidfuzz for edit counts.
"""
import argparse,json,math,pathlib,re,resource,time,wave,hashlib,statistics
import numpy as np
from rapidfuzz.distance import Levenshtein

def normalized(text,language):
    return re.findall(r"[a-z0-9]+(?:'[a-z]+)?",text.lower()) if language=='en' else [c for c in text.lower() if c.isalnum()]

def overlap(previous,current):
    # Same conservative suffix/prefix LCS rule as TranscriptionEngine.
    aa=[c for c in previous.lower() if c.isalnum()];indexed=[i for i,c in enumerate(current) if c.isalnum()]
    bb=[current[i].lower() for i in indexed];limit=min(65,len(aa),len(bb));best=0;count=0
    for n in range(6,limit+1):
      for m in range(max(6,n-5),min(len(bb),n+5)+1):
        row=[0]*(m+1)
        for x in aa[-n:]:
          nxt=[0]*(m+1)
          for j in range(1,m+1):nxt[j]=row[j-1]+1 if x==bb[j-1] else max(row[j],nxt[j-1])
          row=nxt
        ratio=2*row[m]/(n+m);score=ratio*min(n,m)
        if ratio>=.9 and score>best:best=score;count=m
    if not count:return current
    end=indexed[count-1]+1
    while end<len(current) and not current[end].isalnum():end+=1
    return current[end:]

def score(case,text,boundaries):
    ref=normalized(case['reference'],case['language']);hyp=normalized(text,case['language']);ops=Levenshtein.editops(ref,hyp)
    counts={kind:sum(x.tag==kind for x in ops) for kind in ['delete','replace','insert']}
    # Whole utterances intersecting +/-1 second of a cut. These are not exact
    # word-time boundary errors, since no human word timestamps are available.
    ranges=[];cursor=0
    for segment in case['segments']:
        length=len(normalized(segment['text'],case['language']))
        if any(segment['start']-1<=cut<=segment['end']+1 for cut in boundaries):ranges.append((cursor,cursor+length))
        cursor+=length
    affected={i for a,b in ranges for i in range(a,b)}
    counts.update(referenceUnits=len(ref),errorRate=len(ops)/max(1,len(ref)),metric='WER' if case['language']=='en' else 'CER',boundaryAffectedReferenceUnits=len(affected),boundaryAffectedEditCount=sum(x.src_pos in affected for x in ops),adjacentRepeatedUnits=sum(a==b for a,b in zip(hyp,hyp[1:])))
    return counts

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--manifest',type=pathlib.Path,required=True);p.add_argument('--case',required=True);p.add_argument('--model',type=pathlib.Path,required=True);p.add_argument('--window',type=float,required=True);p.add_argument('--overlap',type=float,default=3);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--memory-gib',type=float,default=6);a=p.parse_args()
    assert not a.output.exists() and a.output.parent.is_dir()
    assert 0<=a.overlap<a.window<=300
    case=next(x for x in json.loads(a.manifest.read_text())['cases'] if x['id']==a.case)
    source=pathlib.Path(case['path']);before=hashlib.sha256(source.read_bytes()).hexdigest();assert before==case['sha256']
    with wave.open(str(source),'rb') as f:
        assert f.getframerate()==16000 and f.getnchannels()==1 and f.getsampwidth()==2
        pcm=np.frombuffer(f.readframes(f.getnframes()),dtype='<i2').astype(np.float32)/32768
    import mlx.core as mx
    from mlx_audio.stt import load
    mx.set_memory_limit(int(a.memory_gib*1024**3));mx.set_cache_limit(256*1024**2)
    started=time.monotonic();model=load(a.model);load_seconds=time.monotonic()-started
    mx.reset_peak_memory();windows=[];begin=0;previous='';pieces=[];failure=None
    while begin<len(pcm):
      end=min(len(pcm),begin+int(a.window*16000));audio=pcm[begin:end];duration=len(audio)/16000
      if float(np.max(np.abs(audio)))>2/32768:
       tokens=max(512,min(8192,math.ceil(duration*16)+128));t=time.monotonic()
       try:
        result=model.generate(audio=audio,language={'zh':'Chinese','en':'English'}[case['language']],max_tokens=tokens,temperature=0,chunk_duration=a.window+1,min_chunk_duration=.1,repetition_penalty=1.05,verbose=False)
        elapsed=time.monotonic()-t
        assert len(result.segments)==1,'Library internally split a requested window'
        assert abs(result.segments[0]['end']-duration)<.001,'Internal audio coverage mismatch'
        assert result.generation_tokens<tokens,'Token budget reached; partial result rejected'
        raw=result.text.strip();text=overlap(previous,raw) if a.overlap else raw;pieces.append(text);previous=raw
        windows.append(dict(start=begin/16000,end=end/16000,seconds=elapsed,tokens=result.generation_tokens,tokenLimit=tokens,internalChunks=len(result.segments),raw=raw,text=text))
        mx.clear_cache()
       except Exception as error:
        failure={'type':type(error).__name__,'message':str(error),'start':begin/16000,'end':end/16000};break
      if end==len(pcm):break
      begin+=int((a.window-a.overlap)*16000)
    text='\n'.join(pieces);times=[x['seconds'] for x in windows];result={'case':a.case,'window':a.window,'overlap':a.overlap,'duration':len(pcm)/16000,'status':'FAIL' if failure else 'PASS','failure':failure,'loadSeconds':load_seconds,'inferenceSeconds':sum(times),'realTimeFactor':sum(times)/(len(pcm)/16000),'p50WindowComputeSeconds':statistics.median(times) if times else None,'p95WindowComputeSeconds':sorted(times)[min(len(times)-1,math.ceil(len(times)*.95)-1)] if times else None,'peakMetalBytes':mx.get_peak_memory(),'peakRSSBytes':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,'windows':windows,'text':text,'accuracy':None if failure else score(case,text,[x['start'] for x in windows[1:]]),'inputUnchanged':hashlib.sha256(source.read_bytes()).hexdigest()==before,'model':str(a.model),'memoryLimitGiB':a.memory_gib,'latencyScope':'offline model computation, not UI end-to-end or physical recording'}
    stage=a.output.with_suffix('.partial');stage.write_text(json.dumps(result,ensure_ascii=False,indent=2));stage.replace(a.output)
    print(json.dumps({k:v for k,v in result.items() if k not in ['windows','text','model']},ensure_ascii=False),flush=True)
    return 1 if failure else 0
if __name__=='__main__':raise SystemExit(main())
