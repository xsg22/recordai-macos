#!/usr/bin/env python3
"""Complete-utterance refinement batch benchmark (not microphone/UI latency).

Uses the same public reference corpus as the fixed-cut boundary stress test.
Whole utterances accumulate to a target and flush before the existing 30s cap.
"""
import argparse,hashlib,importlib.util,json,math,pathlib,resource,statistics,time,wave
import numpy as np

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--manifest',type=pathlib.Path,required=True);p.add_argument('--case',required=True);p.add_argument('--model',type=pathlib.Path,required=True);p.add_argument('--target',type=int,required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
    assert a.target in [6,8,12,16] and not a.output.exists()
    spec=importlib.util.spec_from_file_location('qwen_window_benchmark',pathlib.Path(__file__).with_name('benchmark-qwen-windows.py'));bench=importlib.util.module_from_spec(spec);spec.loader.exec_module(bench)
    case=next(x for x in json.loads(a.manifest.read_text())['cases'] if x['id']==a.case)
    path=pathlib.Path(case['path']);before=hashlib.sha256(path.read_bytes()).hexdigest();assert before==case['sha256']
    with wave.open(str(path),'rb') as f:pcm=np.frombuffer(f.readframes(f.getnframes()),dtype='<i2').astype(np.float32)/32768
    batches=[];pending=[]
    for row in case['segments']:
        if pending and row['end']-pending[0]['start']>30:batches.append(pending);pending=[]
        assert row['end']-row['start']<=30
        pending.append(row)
        if row['end']-pending[0]['start']>=a.target:batches.append(pending);pending=[]
    # Explicit tail flush benchmark; production retains the primary live text
    # until final ASR if a recording stops before the refinement target.
    if pending:batches.append(pending)
    import mlx.core as mx
    from mlx_audio.stt import load
    mx.set_memory_limit(6*1024**3);mx.set_cache_limit(256*1024**2)
    t=time.monotonic();model=load(a.model);load_seconds=time.monotonic()-t;mx.reset_peak_memory()
    windows=[];texts=[]
    for batch in batches:
        start=batch[0]['start'];end=batch[-1]['end'];audio=pcm[round(start*16000):round(end*16000)];duration=len(audio)/16000
        tokens=max(512,math.ceil(duration*16)+128);t=time.monotonic()
        result=model.generate(audio=audio,language={'zh':'Chinese','en':'English'}[case['language']],max_tokens=tokens,temperature=0,chunk_duration=241,min_chunk_duration=.1,repetition_penalty=1.05,verbose=False)
        elapsed=time.monotonic()-t
        assert result.generation_tokens<tokens and len(result.segments)==1 and abs(result.segments[0]['end']-duration)<.001
        texts.append(result.text);windows.append(dict(start=start,end=end,seconds=elapsed,tokens=result.generation_tokens,utterances=len(batch),raw=result.text));mx.clear_cache()
    text='\n'.join(texts);times=[x['seconds'] for x in windows];spans=[x['end']-x['start'] for x in windows]
    result=dict(case=a.case,scenario='live-complete-utterance',target=a.target,status='PASS',accuracy=bench.score(case,text,[x['start'] for x in windows[1:]]),duration=len(pcm)/16000,loadSeconds=load_seconds,inferenceSeconds=sum(times),batchCount=len(windows),p95WindowComputeSeconds=sorted(times)[math.ceil(.95*len(times))-1],maximumBatchSeconds=max(spans),meanCollectionSeconds=statistics.mean(spans),estimatedColdLoadPlusComputeRTF=(load_seconds*len(windows)+sum(times))/(len(pcm)/16000),peakMetalBytes=mx.get_peak_memory(),peakRSSBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,windows=windows,text=text,inputUnchanged=hashlib.sha256(path.read_bytes()).hexdigest()==before,latencyScope='Model computation measured. Repeated model load estimate excludes interpreter startup, Paraformer endpoint latency, worker queue and UI rendering. Human utterance boundaries stand in for VAD. Tail flush included.')
    stage=a.output.with_suffix('.partial');stage.write_text(json.dumps(result,ensure_ascii=False,indent=2));stage.replace(a.output)
    print(json.dumps({k:v for k,v in result.items() if k not in ['windows','text']},ensure_ascii=False))
if __name__=='__main__':main()
