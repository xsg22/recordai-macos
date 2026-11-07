"""Persist the bounded Sortformer speaker cache, never a model or full recording.

Each job writes into an isolated candidate context. The parent commits that
context only alongside its transcript checkpoint, making retries idempotent.
"""
import json,pathlib

ARRAYS=('spkcache','spkcache_preds','fifo','fifo_preds','mean_sil_emb','n_sil_frames')

def restore(model,path,mx):
    path=pathlib.Path(path)
    if not path.exists():return model.init_streaming_state(),0.0
    meta=json.loads(path.read_text())
    if meta.get('version')!=1 or not 0<=meta['seconds']<=60*60*24*7:raise ValueError('Invalid speaker checkpoint')
    weights=mx.load(str(path.with_suffix('.safetensors')))
    if set(weights)!=set(ARRAYS):raise ValueError('Incomplete speaker checkpoint')
    state=model.init_streaming_state()
    for key in ARRAYS:setattr(state,key,weights[key])
    state.frames_processed=int(meta['framesProcessed'])
    if state.fifo.shape[1]>600 or state.spkcache.shape[1]>4000:raise ValueError('Unbounded speaker checkpoint')
    return state,float(meta['seconds'])

def save(state,path,seconds,mx):
    path=pathlib.Path(path)
    values={key:getattr(state,key)for key in ARRAYS};mx.eval(*values.values())
    mx.save_safetensors(str(path.with_suffix('.safetensors')),values)
    path.write_text(json.dumps(dict(version=1,seconds=seconds,framesProcessed=state.frames_processed)))
