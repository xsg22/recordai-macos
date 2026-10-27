import subprocess,time,json,wave,struct,threading,sys
# 从仓库根目录运行；仅使用构建期生成的合成中文音频。
p=subprocess.Popen(['.build/paraformer-live','.models/ASR/Paraformer','zh'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open('.tools/paraformer-engine.log','w'))
events=[];t=time.monotonic();eof=False
ready=threading.Event()
def read():
 for line in p.stdout:
  j=json.loads(line);events.append(j);print(round(time.monotonic()-t,3),j,flush=True)
  if j['type']=='ready':ready.set()
thread=threading.Thread(target=read);thread.start();assert ready.wait(30),'load timeout'
with wave.open('.tools/asr-chinese.wav') as w:
 pcm=w.readframes(w.getnframes())
 samples=struct.unpack('<'+'h'*(len(pcm)//2),pcm)
 for i in range(0,len(samples),1600):
  values=[v/32768 for v in samples[i:i+1600]];p.stdin.write(struct.pack('<I',len(values))+struct.pack('<'+'f'*len(values),*values));p.stdin.flush();time.sleep(.1)
  if any(j['type']=='partial' for j in events) and not eof:print('PARTIAL_BEFORE_EOF',flush=True);eof=True
p.stdin.close();assert p.wait(timeout=20)==0;thread.join()
assert any(x['type']=='commit' and any('\u4e00'<=c<='\u9fff' for c in x['text']) for x in events)
assert eof,'partial must precede EOF'
silence=struct.pack('<I',1600)+struct.pack('<1600f',*([0]*1600))
r=subprocess.run(['.build/paraformer-live','.models/ASR/Paraformer','zh'],input=silence*40,capture_output=True,timeout=30)
assert r.returncode==0,r.stderr.decode();se=[json.loads(x) for x in r.stdout.splitlines()];assert not any(j['type'] in ['partial','commit'] and j['text'] for j in se)
print('PASS: 中文partial在EOF前出现、最终commit/done、四秒纯静音不出字',flush=True)
