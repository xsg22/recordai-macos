#!/usr/bin/env python3
"""Send real-time PCM into the packaged live worker; never records a microphone."""
import argparse, array, json, os, queue, struct, subprocess, threading, time, wave
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--engine',type=Path,required=True);p.add_argument('--model',type=Path,required=True)
p.add_argument('--repeats',type=int,default=2);p.add_argument('--audio',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
a=p.parse_args();a.output.mkdir(parents=True,exist_ok=False)
with wave.open(str(a.audio),'rb') as w:
 assert (w.getnchannels(),w.getsampwidth(),w.getframerate())==(1,2,16000)
 samples=array.array('h');samples.frombytes(w.readframes(w.getnframes()))
raw=array.array('f',(x/32768 for x in samples)).tobytes();step=1600*4
error_log=(a.output/'worker.log').open('w')
# Match LiveTranscriptionSession, including its explicit hotword request file.
# Some installed runtimes require this argument even for an empty vocabulary.
hotwords=a.output/'hotwords.json'
hotwords.write_text(json.dumps({'words':[],'context':''}))
child=subprocess.Popen(['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)',str(a.engine),'--live',str(a.model),'yue',str(hotwords)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=error_log,env=dict(os.environ,HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1'))
messages=queue.Queue();events=[];begin=time.monotonic()
def read():
 for line in child.stdout:
  try:e=json.loads(line)
  except Exception:continue
  e['observedSeconds']=time.monotonic()-begin;events.append(e);messages.put(e)
threading.Thread(target=read,daemon=True).start()
try:
 ready=messages.get(timeout=60);assert ready['type']=='ready',ready
 feed_start=time.monotonic();first_pass_end=None;resume_at=None
 def send(pcm):
  child.stdin.write(struct.pack('<I',len(pcm)//4)+pcm);child.stdin.flush()
 for index in range(a.repeats):
  pass_start=time.monotonic()
  for pos in range(0,len(raw),step):
   data=raw[pos:pos+step];send(data)
   next_at=pass_start+(pos+len(data))/4/16000
   time.sleep(max(0,next_at-time.monotonic()))
  if index==0:
   first_pass_end=time.monotonic()-begin
   # Pause produces no PCM and must not tear down or reload the worker.
   time.sleep(3)
   assert any(e['type']=='commit' for e in events),'Pause did not finalize a phrase'
   resume_at=time.monotonic()-begin
 stop_at=time.monotonic()-begin;child.stdin.close();child.wait(timeout=15)
 assert child.returncode==0,'Worker failed; inspect worker.log'
 assert any(e['type']=='done' for e in events),'EOF did not drain the final phrase'
 captions=[e for e in events if e['type'] in ('partial','commit') and e['text'].strip()]
 assert captions and captions[0]['observedSeconds']<stop_at,'No subtitles while recording'
 assert sum(e['observedSeconds']<stop_at for e in captions)>=2,'Only the final output was emitted'
 assert sum(e['type']=='ready' for e in events)==1,'Pause/resume reloaded the model'
 commits=[e for e in captions if e['type']=='commit'];assert any(e['observedSeconds']>resume_at for e in commits),'No recognized audio after resume'
 total_audio=len(samples)*a.repeats/16000
 assert all(0<=e['start']<=e['end']<=total_audio+.001 for e in captions),'Invalid audio timestamps'
 text=''.join(e['text'] for e in commits)
 assert any(t in text for t in ['我哋','喺','唔好','咗']),text
 report={'status':'PASS','networkDenied':True,'input':'synthetic Cantonese speech','firstCaptionSecondsAfterInput':captions[0]['observedSeconds']-(feed_start-begin),'subtitlesBeforeEOF':sum(e['observedSeconds']<stop_at for e in captions),'pauseFinalized':True,'resumeRecognized':True,'modelReadyEvents':1,'commits':len(commits),'audioSeconds':total_audio,'stopDrainSeconds':time.monotonic()-begin-stop_at,'text':text}
 (a.output/'events.json').write_text(json.dumps(events,ensure_ascii=False,indent=2));(a.output/'result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2));print(json.dumps(report,ensure_ascii=False))
finally:
 if child.poll() is None:child.terminate();child.wait(timeout=10)
 error_log.close()
