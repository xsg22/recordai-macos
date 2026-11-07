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

def diarize(model_path,audio_path,output,streaming=False,checkpoint=None):
    import miniaudio,numpy as np
    import mlx.core as mx
    from mlx_audio.vad import load
    configure_memory(mx)
    model=load(pathlib.Path(model_path).resolve(strict=True),strict=True)
    from speaker_timeline import SpeakerTimeline
    from diarization_checkpoint import restore,save
    state,base=restore(model,checkpoint,mx) if checkpoint else (model.init_streaming_state(),0.0)
    skip=float(json.loads(pathlib.Path(checkpoint).read_text()).get('skipSeconds',0)) if checkpoint and pathlib.Path(checkpoint).exists() else 0
    if not 0<=skip<=3.001:raise ValueError('Invalid diarization overlap')
    remaining=round(skip*16000)
    offset=0.0
    frame_duration=model.config.processor_config.hop_length*model.config.fc_encoder_config.subsampling_factor/16000
    timeline=SpeakerTimeline(frame_duration)
    chunks=(pcm_chunks(sys.stdin.buffer) if streaming else miniaudio.stream_file(audio_path,output_format=miniaudio.SampleFormat.FLOAT32,nchannels=1,sample_rate=16000,frames_to_read=240000))
    for chunk in chunks:
        samples=(np.frombuffer(chunk,dtype='<f4') if streaming else np.asarray(chunk,dtype=np.float32));duration=len(samples)/16000
        if remaining:
            n=min(remaining,len(samples));samples=samples[n:];remaining-=n;offset+=n/16000;duration=len(samples)/16000
            if not len(samples):continue
        # Offline finalization can revise the preceding chunk after more voice
        # context. Retain two transport chunks in a bounded FIFO, not a new
        # speaker identity space per ASR window.
        result,state=model.feed(samples,state,sample_rate=16000,threshold=0.5,min_duration=0.12,merge_gap=0.16,fifo_max=376)
        scores=np.asarray(result.speaker_probs).tolist()
        revised=np.asarray(state.fifo_preds)[0].tolist()
        # Earlier FIFO frames are already in the durable prior job; preserve
        # their identity cache but only revise frames present in this job.
        revised=revised[-(len(timeline.scores)+len(scores)):] if scores or timeline.scores else []
        timeline.append(scores,offset,duration,revised)
        offset+=duration;mx.clear_cache()
        print('Sortformer: %.1fs'%offset,file=sys.stderr,flush=True)
    pathlib.Path(output).write_text(json.dumps(dict(turns=timeline.turns(),frames=timeline.frames(),duration=offset,retrospectiveFIFO=True,frameCount=len(timeline.times))))
    if checkpoint:save(state,checkpoint,base+offset-skip,mx)

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

def recognized_segment(model,audio,*,start,end,language,hotwords=None):
    generated=generate_complete(model,audio,language=language,hotwords=hotwords)
    text=generated.text.strip();segment=dict(text=text,start=start,end=end)
    if text and len(audio)/16000>MAX_ALIGNMENT_SECONDS:
        from alignment_windows import prepare,AlignmentWindowError
        try:
            parts=prepare(model,audio,text,language=language,hotwords=hotwords)
            segment['alignmentParts']=[dict(text=p['text'],start=start+p['start'],end=start+p['end']) for p in parts]
        except (AlignmentWindowError,ValueError) as error:
            # Recognition remains authoritative; optional speaker/timestamp
            # analysis must not invent timing or erase this completed text.
            segment['alignmentIssue']=str(error)
            print('Bounded alignment preparation unavailable: '+str(error),file=sys.stderr,flush=True)
    return segment

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
        segment=recognized_segment(model,np.frombuffer(data,dtype='<f4'),start=clip['start'],end=clip['end'],language=selected_language,hotwords=select_hotwords(words,context) or None)
        result.append(segment)
        context=(context+' '+segment['text'])[-2000:];mx.clear_cache()
    output=pathlib.Path(output);temp=output.with_suffix('.partial')
    temp.write_text(json.dumps({'segments':result},ensure_ascii=False));temp.replace(output)

def align_stream(model_path,turns_path,output):
    import numpy as np
    import mlx.core as mx
    from mlx_audio.stt import load
    configure_memory(mx)
    from speaker_attribution import aligned_words
    from sentence_speakers import attribute_sentences
    voice=json.loads(pathlib.Path(turns_path).read_text())
    model=load(pathlib.Path(model_path).resolve(strict=True));paragraphs=[]
    hotwords=[]
    for index,(clip,data) in enumerate(stream_clips(MAX_ALIGNMENT_SECONDS)):
        text=clip.get('text');language=clip.get('language','auto')
        if not isinstance(text,str) or not text or len(text)>100000:raise ValueError('Invalid alignment text')
        aligned=model.generate(audio=np.frombuffer(data,dtype='<f4'),text=text,language=alignment_language(language,text))
        items=[dict(text=i.text,start=i.start_time,end=i.end_time) for i in aligned.items]
        rows=aligned_words(text,items,clip['start'],clip['end']-clip['start'])
        hotwords.extend(clip.get('hotwords',[]))
        if rows:rows[0]['separator']=clip.get('separator','' if index==0 else '\n')
        paragraphs.extend(rows);mx.clear_cache()
    words=paragraphs
    paragraphs=attribute_sentences(words,voice['turns'],frames=voice.get('frames'),protected_words=hotwords)
    pathlib.Path(output).write_text(json.dumps(dict(paragraphs=paragraphs,alignedWords=words,attributionPolicy='sentence-v1'),ensure_ascii=False))

def align_speakers(model_path,manifest_path,turns_path,output):
    import numpy as np
    import mlx.core as mx
    from mlx_audio.stt import load
    configure_memory(mx)
    from speaker_attribution import aligned_words
    from sentence_speakers import attribute_sentences
    manifest=pathlib.Path(manifest_path).resolve(strict=True);clips=json.loads(manifest.read_text())
    voice=json.loads(pathlib.Path(turns_path).read_text())
    model=load(pathlib.Path(model_path).resolve(strict=True));paragraphs=[]
    hotwords=[]
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
        rows=aligned_words(clip['text'],items,clip['start'],clip['end']-clip['start'])
        hotwords.extend(clip.get('hotwords',[]))
        if rows:rows[0]['separator']=clip.get('separator','' if index==0 else '\n')
        paragraphs.extend(rows);mx.clear_cache()
        print('ForcedAligner: %d/%d'%(index+1,len(clips)),file=sys.stderr,flush=True)
    words=paragraphs
    paragraphs=attribute_sentences(words,voice['turns'],frames=voice.get('frames'),protected_words=hotwords)
    pathlib.Path(output).write_text(json.dumps(dict(paragraphs=paragraphs,alignedWords=words,attributionPolicy='sentence-v1'),ensure_ascii=False))

def main():
    if len(sys.argv)==7 and sys.argv[1]=='--splice-seam':
        from overlap_words import splice_prefix
        source,prefix,count,seconds,output=sys.argv[2:]
        old=json.loads(pathlib.Path(source).read_text());new=json.loads(pathlib.Path(prefix).read_text())
        words=splice_prefix(old['alignedWords'],new['alignedWords'],int(count),float(seconds))
        pathlib.Path(output).write_text(json.dumps(dict(alignedWords=words),ensure_ascii=False));return
    if len(sys.argv)==7 and sys.argv[1]=='--crop-speakers':
        from speaker_attribution import normalized
        from sentence_speakers import attribute_sentences
        source,voice,cut,prior,output=sys.argv[2:];cut=float(cut)
        data=json.loads(pathlib.Path(source).read_text());words=data['alignedWords'];hints=json.loads(pathlib.Path(prior).read_text());context=hints['context']
        from overlap_words import crop
        proof=[];words,dropped=crop(words,cut,context,proof)
        if words:words[0]['separator']=''
        v=json.loads(pathlib.Path(voice).read_text());rows=attribute_sentences(words,v['turns'],frames=v.get('frames'),protected_words=hints['words'])
        pathlib.Path(output).write_text(json.dumps(dict(paragraphs=rows,text=''.join(r.get('separator','')+r['text']for r in rows),discardedOverlap=''.join(w['text']for w in dropped),seamOwnership=proof),ensure_ascii=False));return
    if len(sys.argv)==5 and sys.argv[1]=='--diarize-stream-checkpoint':
        diarize(sys.argv[2],None,sys.argv[3],streaming=True,checkpoint=sys.argv[4]);return
    if len(sys.argv)==6 and sys.argv[1]=='--diarize-checkpoint':
        diarize(sys.argv[2],sys.argv[3],sys.argv[4],checkpoint=sys.argv[5]);return
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
            segment=recognized_segment(model,audio,start=clip['start'],end=clip['end'],language=selected_language,hotwords=selected or None)
            result.append(segment)
            context=(context+' '+segment['text'])[-2000:]
            print('Qwen3-ASR: %d/%d'%(index+1,len(clips)),file=sys.stderr,flush=True)
            mx.clear_cache()
    output=pathlib.Path(output);temp=output.with_suffix('.partial')
    temp.write_text(json.dumps({'segments':result},ensure_ascii=False));temp.replace(output)

if __name__=='__main__':
    # 冻结运行时的资源追踪子进程必须先分流，不能误作ASR请求。
    import multiprocessing
    multiprocessing.freeze_support()
    try:
        from inference_lock import exclusive
        if len(sys.argv)>1 and sys.argv[1]=='--live':main()
        else:
            with exclusive():main()
    except Exception as e:
        print('本地Qwen3-ASR推理失败：'+str(e),file=sys.stderr,flush=True)
        sys.exit(1)
