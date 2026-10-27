"""隔离的离线MLX推理进程；音频由Silero分段，文字不交给Gemma改写。"""
import os
# 在导入运行时之前关闭模型/分词器的任何在线回退。
os.environ['HF_HUB_OFFLINE']='1'
os.environ['TRANSFORMERS_OFFLINE']='1'
os.environ['TOKENIZERS_PARALLELISM']='false'
import json,math,pathlib,sys,wave

def diarize(model_path,audio_path,output):
    import miniaudio,numpy as np
    import mlx.core as mx
    from mlx_audio.vad import load
    model=load(pathlib.Path(model_path).resolve(strict=True),strict=True)
    state=model.init_streaming_state();segments=[];offset=0.0
    frame_duration=model.config.processor_config.hop_length*model.config.fc_encoder_config.subsampling_factor/16000
    chunks=miniaudio.stream_file(audio_path,output_format=miniaudio.SampleFormat.FLOAT32,nchannels=1,sample_rate=16000,frames_to_read=240000)
    for chunk in chunks:
        samples=np.asarray(chunk,dtype=np.float32);duration=len(samples)/16000
        before=state.frames_processed*frame_duration
        result,state=model.feed(samples,state,sample_rate=16000,threshold=0.5,min_duration=0.12,merge_gap=0.16)
        for seg in result.segments:
            start=offset+max(0,min(duration,seg.start-before));end=offset+max(0,min(duration,seg.end-before))
            if end>start:segments.append(dict(start=start,end=end,speaker=str(seg.speaker)))
        offset+=duration;mx.clear_cache()
        print('Sortformer: %.1fs'%offset,file=sys.stderr,flush=True)
    # 同一个声音相邻活动片段合并；保留不同声音的重叠区。
    merged=[]
    for speaker in sorted(set(t['speaker'] for t in segments)):
        for turn in sorted((t for t in segments if t['speaker']==speaker),key=lambda t:t['start']):
            if merged and merged[-1]['speaker']==speaker and turn['start']-merged[-1]['end']<=.16:merged[-1]['end']=max(merged[-1]['end'],turn['end'])
            else:merged.append(turn.copy())
    pathlib.Path(output).write_text(json.dumps(dict(turns=sorted(merged,key=lambda x:x['start']),duration=offset)))

def align_speakers(model_path,manifest_path,turns_path,output):
    import numpy as np
    import mlx.core as mx
    from mlx_audio.stt import load
    from speaker_attribution import attribute
    manifest=pathlib.Path(manifest_path).resolve(strict=True);clips=json.loads(manifest.read_text())
    turns=json.loads(pathlib.Path(turns_path).read_text())['turns']
    model=load(pathlib.Path(model_path).resolve(strict=True));paragraphs=[]
    for index,clip in enumerate(clips):
        path=pathlib.Path(clip['audio']).resolve(strict=True)
        if path.parent!=manifest.parent:raise ValueError('Invalid alignment audio path')
        with wave.open(str(path),'rb') as w:
            if w.getframerate()!=16000 or w.getnchannels()!=1 or w.getsampwidth()!=2:raise ValueError('Invalid alignment audio format')
            audio=np.frombuffer(w.readframes(w.getnframes()),dtype='<i2').astype(np.float32)/32768
        # 中文分词器也支持混合拉丁词；显式英语使用英语分词。
        language='English' if clip.get('language')=='en' else 'Chinese'
        aligned=model.generate(audio=audio,text=clip['text'],language=language)
        items=[dict(text=i.text,start=i.start_time,end=i.end_time) for i in aligned.items]
        rows=attribute(clip['text'],items,turns,clip['start'],clip['end']-clip['start'])
        if rows:rows[0]['separator']='' if index==0 else '\n'
        paragraphs.extend(rows);mx.clear_cache()
        print('ForcedAligner: %d/%d'%(index+1,len(clips)),file=sys.stderr,flush=True)
    pathlib.Path(output).write_text(json.dumps(dict(paragraphs=paragraphs),ensure_ascii=False))

def main():
    if len(sys.argv)==5 and sys.argv[1]=='--diarize':
        diarize(*sys.argv[2:]);return
    if len(sys.argv)==6 and sys.argv[1]=='--align-speakers':
        align_speakers(*sys.argv[2:]);return
    if len(sys.argv)!=5:raise ValueError('usage: qwen-asr modelDirectory segmentsJSON language outputJSON')
    model_path,manifest,language,output=sys.argv[1:]
    model_path=pathlib.Path(model_path).resolve(strict=True)
    manifest=pathlib.Path(manifest).resolve(strict=True)
    clips=json.loads(manifest.read_text())
    languages={'zh':'Chinese','en':'English','ja':'Japanese','auto':None}
    if language not in languages:raise ValueError('Unsupported language')
    for clip in clips:
        start,end=clip['start'],clip['end']
        path=pathlib.Path(clip['audio']).resolve(strict=True)
        if path.parent!=manifest.parent or not (math.isfinite(start) and math.isfinite(end) and 0<=start<end and end-start<=30):
            raise ValueError('Invalid speech clip')
        with wave.open(str(path),'rb') as w:
            if w.getframerate()!=16000 or w.getnchannels()!=1 or w.getsampwidth()!=2:raise ValueError('Expected mono PCM16 16kHz')
    result=[]
    if clips:
        import numpy as np
        import mlx.core as mx
        from mlx_audio.stt import load
        model=load(model_path)
        for index,clip in enumerate(clips):
            with wave.open(clip['audio'],'rb') as w:audio=np.frombuffer(w.readframes(w.getnframes()),dtype='<i2').astype(np.float32)/32768
            generated=model.generate(audio=audio,language=languages[language],max_tokens=512,temperature=0,
                                     chunk_duration=30,min_chunk_duration=0.1,repetition_penalty=1.05,verbose=False)
            if generated.generation_tokens>=512:raise ValueError('Transcript token limit reached; partial result not saved')
            result.append(dict(text=generated.text.strip(),start=clip['start'],end=clip['end']))
            print('Qwen3-ASR: %d/%d'%(index+1,len(clips)),file=sys.stderr,flush=True)
            mx.clear_cache()
    output=pathlib.Path(output);temp=output.with_suffix('.partial')
    temp.write_text(json.dumps({'segments':result},ensure_ascii=False));temp.replace(output)

if __name__=='__main__':
    # 冻结运行时的资源追踪子进程必须先分流，不能误作ASR请求。
    import multiprocessing
    multiprocessing.freeze_support()
    try:main()
    except Exception as e:
        print('本地Qwen3-ASR推理失败：'+str(e),file=sys.stderr,flush=True)
        sys.exit(1)
