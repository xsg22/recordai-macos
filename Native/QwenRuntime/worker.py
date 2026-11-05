"""隔离的离线MLX推理进程；音频由Silero分段，文字不交给Gemma改写。"""
import os
# 在导入运行时之前关闭模型/分词器的任何在线回退。
os.environ['HF_HUB_OFFLINE']='1'
os.environ['TRANSFORMERS_OFFLINE']='1'
os.environ['TOKENIZERS_PARALLELISM']='false'
import json,math,pathlib,struct,sys,wave
from language_policy import recognition_language, alignment_language
from inference_policy import MAX_ASR_SECONDS, MAX_ALIGNMENT_SECONDS, validate_clip, generate_complete, configure_memory

def select_hotwords(words, context, limit=12):
    matched=[w for w in words if w.casefold() in context.casefold()]
    return (matched + [w for w in reversed(words) if w not in matched])[:limit]

def extract_hotwords(model_path,input_path,output_path):
    import mlx.core as mx
    from mlx_audio.lm.models import qwen2
    from mlx_audio.lm.generate import generate
    from mlx_audio.utils import load_config,load_weights,apply_quantization
    from transformers import AutoTokenizer
    model_path=pathlib.Path(model_path).resolve(strict=True)
    payload=json.loads(pathlib.Path(input_path).read_text())
    system,prompt=payload['system'],payload['prompt']
    if not isinstance(system,str) or not isinstance(prompt,str) or len(system)+len(prompt)>7000:raise ValueError('Invalid extraction input')
    config=load_config(model_path)
    if config.get('model_type')!='qwen2':raise ValueError('Invalid extraction model')
    model=qwen2.Model(qwen2.ModelArgs.from_dict(config))
    weights=load_weights(model_path);apply_quantization(model,config,weights)
    model.load_weights(list(model.sanitize(weights).items()));mx.eval(model.parameters())
    tokenizer=AutoTokenizer.from_pretrained(model_path,local_files_only=True,trust_remote_code=False)
    # Qwen2.5's fixed chat framing; escape transcript-supplied special-token delimiters.
    system=system.replace('<|','＜|');prompt=prompt.replace('<|','＜|')
    text=f'<|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n{prompt}<|im_end|>\n<|im_start|>assistant\n'
    answer=generate(model,tokenizer,text,max_tokens=384,verbose=False)
    pathlib.Path(output_path).write_text(json.dumps({'text':answer},ensure_ascii=False))

def pcm_chunks(stream):
    while True:
        data=stream.read(240000*4)
        if not data:return
        if len(data)%4:raise ValueError('Incomplete PCM stream')
        yield data

def diarize(model_path,audio_path,output,streaming=False):
    import miniaudio,numpy as np
    import mlx.core as mx
    from mlx_audio.vad import load
    model=load(pathlib.Path(model_path).resolve(strict=True),strict=True)
    state=model.init_streaming_state();segments=[];offset=0.0
    frame_duration=model.config.processor_config.hop_length*model.config.fc_encoder_config.subsampling_factor/16000
    chunks=(pcm_chunks(sys.stdin.buffer) if streaming else miniaudio.stream_file(audio_path,output_format=miniaudio.SampleFormat.FLOAT32,nchannels=1,sample_rate=16000,frames_to_read=240000))
    for chunk in chunks:
        samples=(np.frombuffer(chunk,dtype='<f4') if streaming else np.asarray(chunk,dtype=np.float32));duration=len(samples)/16000
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

def stream_clips(max_seconds=MAX_ASR_SECONDS):
    stream=sys.stdin.buffer
    while True:
        prefix=stream.read(4)
        if not prefix:return
        if len(prefix)!=4:raise ValueError('Incomplete clip header')
        size=struct.unpack('<I',prefix)[0]
        if not 0<size<=65536:raise ValueError('Invalid clip header size')
        raw=stream.read(size)
        if len(raw)!=size:raise ValueError('Incomplete clip metadata')
        item=json.loads(raw);frames=item.get('frames')
        start,end=item.get('start'),item.get('end')
        validate_clip(item,max_seconds)
        data=stream.read(frames*4)
        if len(data)!=frames*4:raise ValueError('Incomplete clip PCM')
        yield item,data

def transcribe_stream(model_path,language,output,hints_path):
    import numpy as np
    import mlx.core as mx
    from mlx_audio.stt import load
    hints=json.loads(pathlib.Path(hints_path).read_text());words=hints.get('words',[]);context=hints.get('context','')
    if not isinstance(words,list) or len(words)>1000 or any(not isinstance(w,str) or not 2<=len(w)<=40 or '\n' in w or '\r' in w for w in words):raise ValueError('Invalid hotwords')
    if not isinstance(context,str) or len(context)>2000:raise ValueError('Invalid hotword context')
    configure_memory(mx)
    model=load(pathlib.Path(model_path).resolve(strict=True));selected_language=recognition_language(language);result=[]
    for clip,data in stream_clips():
        generated=generate_complete(model,np.frombuffer(data,dtype='<f4'),language=selected_language,hotwords=select_hotwords(words,context) or None)
        result.append(dict(text=generated.text.strip(),start=clip['start'],end=clip['end']))
        context=(context+' '+generated.text)[-2000:];mx.clear_cache()
    output=pathlib.Path(output);temp=output.with_suffix('.partial')
    temp.write_text(json.dumps({'segments':result},ensure_ascii=False));temp.replace(output)

def align_stream(model_path,turns_path,output):
    import numpy as np
    import mlx.core as mx
    from mlx_audio.stt import load
    from speaker_attribution import attribute
    turns=json.loads(pathlib.Path(turns_path).read_text())['turns']
    model=load(pathlib.Path(model_path).resolve(strict=True));paragraphs=[]
    for index,(clip,data) in enumerate(stream_clips(MAX_ALIGNMENT_SECONDS)):
        text=clip.get('text');language=clip.get('language','auto')
        if not isinstance(text,str) or not text or len(text)>100000:raise ValueError('Invalid alignment text')
        aligned=model.generate(audio=np.frombuffer(data,dtype='<f4'),text=text,language=alignment_language(language,text))
        items=[dict(text=i.text,start=i.start_time,end=i.end_time) for i in aligned.items]
        rows=attribute(text,items,turns,clip['start'],clip['end']-clip['start'])
        if rows:rows[0]['separator']='' if index==0 else '\n'
        paragraphs.extend(rows);mx.clear_cache()
    pathlib.Path(output).write_text(json.dumps(dict(paragraphs=paragraphs),ensure_ascii=False))

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
        language=alignment_language(clip.get('language','auto'),clip['text'])
        aligned=model.generate(audio=audio,text=clip['text'],language=language)
        items=[dict(text=i.text,start=i.start_time,end=i.end_time) for i in aligned.items]
        rows=attribute(clip['text'],items,turns,clip['start'],clip['end']-clip['start'])
        if rows:rows[0]['separator']='' if index==0 else '\n'
        paragraphs.extend(rows);mx.clear_cache()
        print('ForcedAligner: %d/%d'%(index+1,len(clips)),file=sys.stderr,flush=True)
    pathlib.Path(output).write_text(json.dumps(dict(paragraphs=paragraphs),ensure_ascii=False))

def main():
    if len(sys.argv)==6 and sys.argv[1]=='--transcribe-stream':
        transcribe_stream(*sys.argv[2:]);return
    if len(sys.argv)==5 and sys.argv[1]=='--align-stream':
        align_stream(*sys.argv[2:]);return
    if len(sys.argv)==4 and sys.argv[1]=='--diarize-stream':
        diarize(sys.argv[2],None,sys.argv[3],streaming=True);return
    if len(sys.argv) in (4,5) and sys.argv[1]=='--live':
        from live_transcription import run_live
        run_live(*sys.argv[2:]);return
    if len(sys.argv)==5 and sys.argv[1]=='--extract-hotwords':
        extract_hotwords(*sys.argv[2:]);return
    if len(sys.argv)==5 and sys.argv[1]=='--diarize':
        diarize(*sys.argv[2:]);return
    if len(sys.argv)==6 and sys.argv[1]=='--align-speakers':
        align_speakers(*sys.argv[2:]);return
    if len(sys.argv) not in (5,6):raise ValueError('usage: qwen-asr modelDirectory segmentsJSON language outputJSON [hotwordsJSON]')
    model_path,manifest,language,output=sys.argv[1:5]
    hints=json.loads(pathlib.Path(sys.argv[5]).read_text()) if len(sys.argv)==6 else {}
    words=hints.get('words',[])
    if not isinstance(words,list) or len(words)>1000 or any(not isinstance(w,str) or not 2<=len(w)<=40 or '\n' in w or '\r' in w for w in words):raise ValueError('Invalid hotwords')
    context=hints.get('context','')
    if not isinstance(context,str) or len(context)>2000:raise ValueError('Invalid hotword context')
    model_path=pathlib.Path(model_path).resolve(strict=True)
    manifest=pathlib.Path(manifest).resolve(strict=True)
    clips=json.loads(manifest.read_text())
    selected_language=recognition_language(language)
    for clip in clips:
        start,end=clip['start'],clip['end']
        path=pathlib.Path(clip['audio']).resolve(strict=True)
        if path.parent!=manifest.parent or not (math.isfinite(start) and math.isfinite(end) and 0<=start<end and end-start<=MAX_ASR_SECONDS):
            raise ValueError('Invalid speech clip')
        with wave.open(str(path),'rb') as w:
            if w.getframerate()!=16000 or w.getnchannels()!=1 or w.getsampwidth()!=2:raise ValueError('Expected mono PCM16 16kHz')
    result=[]
    if clips:
        import numpy as np
        import mlx.core as mx
        from mlx_audio.stt import load
        configure_memory(mx)
        model=load(model_path)
        for index,clip in enumerate(clips):
            with wave.open(clip['audio'],'rb') as w:audio=np.frombuffer(w.readframes(w.getnframes()),dtype='<i2').astype(np.float32)/32768
            validate_clip(dict(frames=len(audio),start=clip['start'],end=clip['end']))
            selected=select_hotwords(words,context)
            generated=generate_complete(model,audio,language=selected_language,hotwords=selected or None)
            result.append(dict(text=generated.text.strip(),start=clip['start'],end=clip['end']))
            context=(context+' '+generated.text)[-2000:]
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
