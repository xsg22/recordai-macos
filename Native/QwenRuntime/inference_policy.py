"""Explicit local transport/decoder limits, independent of model capability.

The original model supports 1200s; local app windows remain deliberately bounded.
Alignment has its own 300s model limit. Never silently split or truncate input.
"""
import math

RATE = 16000
MAX_ASR_SECONDS = 240
MAX_ALIGNMENT_SECONDS = 300

def configure_memory(mx):
    info=mx.device_info()
    budget=min(6*1024**3,int(info['memory_size']*.5),int(info['max_recommended_working_set_size']*.8))
    mx.set_memory_limit(budget)
    mx.set_cache_limit(256*1024**2)

def token_budget(duration):
    if not math.isfinite(duration) or not 0 < duration <= MAX_ASR_SECONDS:
        raise ValueError('Invalid local ASR window duration')
    return max(512,min(8192,math.ceil(duration*16)+128))

def validate_clip(item,max_seconds=MAX_ASR_SECONDS):
    frames=item.get('frames');start=item.get('start');end=item.get('end')
    if (isinstance(frames,bool) or not isinstance(frames,int) or not 0<frames<=max_seconds*RATE
        or isinstance(start,bool) or isinstance(end,bool) or not isinstance(start,(int,float)) or not isinstance(end,(int,float))
        or not (math.isfinite(start) and math.isfinite(end) and 0<=start<end and end-start<=max_seconds+.00001)
        or abs(frames-round((end-start)*RATE))>1):
        raise ValueError('Invalid clip metadata or incomplete audio coverage')

def generate_complete(model,audio,*,language,hotwords=None):
    duration=len(audio)/RATE;limit=token_budget(duration)
    result=model.generate(audio=audio,language=language,hotwords=hotwords,max_tokens=limit,temperature=0,
        chunk_duration=MAX_ASR_SECONDS+1,min_chunk_duration=.1,repetition_penalty=1.05,verbose=False)
    if result.generation_tokens>=limit:
        raise ValueError('Transcript token limit reached; partial result not saved')
    if (len(result.segments)!=1 or abs(result.segments[0]['start'])>.001
        or abs(result.segments[0]['end']-duration)>.001):
        raise ValueError('Inference library split or truncated the audio window; partial result not saved')
    return result
