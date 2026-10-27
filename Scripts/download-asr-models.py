#!/usr/bin/env python3
"""固定文件与校验清单；分块断点下载，仅接受严格匹配的HTTP Range。"""
import concurrent.futures,hashlib,json,pathlib,urllib.request,time,os
ROOT=pathlib.Path(__file__).resolve().parent.parent
DEST=ROOT/'.models'/'ASR'
OPENER=urllib.request.build_opener(urllib.request.ProxyHandler({}))
CHUNK=4*1024*1024

def digest(p):
 with p.open('rb') as h:return hashlib.file_digest(h,'sha256').hexdigest()

def download(f):
 p=DEST/f['path'];p.parent.mkdir(parents=True,exist_ok=True)
 if p.exists() and p.stat().st_size==f['bytes'] and digest(p)==f['sha256']:return
 parts=p.parent/(p.name+'.parts');parts.mkdir(exist_ok=True)
 def part(i):
  start=i*CHUNK;end=min(f['bytes'],start+CHUNK)-1;path=parts/str(i)
  if path.exists() and path.stat().st_size==end-start+1:return
  for attempt in range(8):
   try:
    req=urllib.request.Request(f['url']+'?cohear_range='+str(i),headers={'Range':f'bytes={start}-{end}'})
    with OPENER.open(req,timeout=35) as r:
     if r.status==206:
      assert r.headers.get('Content-Range')==f"bytes {start}-{end}/{f['bytes']}"
     else:assert start==0 and f['bytes']<=CHUNK
     with path.with_suffix('.partial').open('wb') as out:
      received=0
      while c:=r.read(min(262144,end-start+2-received)):
       received+=len(c)
       if received>end-start+1:raise ValueError('oversized response')
       out.write(c)
     assert received==end-start+1
    path.with_suffix('.partial').replace(path);return
   except Exception as e:
    if attempt==7:raise RuntimeError(str(p)+' '+str(e))
    time.sleep(min(3,attempt+1))
 with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:list(pool.map(part,range((f['bytes']+CHUNK-1)//CHUNK)))
 tmp=p.with_suffix(p.suffix+'.partial')
 with tmp.open('wb') as out:
  for i in range((f['bytes']+CHUNK-1)//CHUNK):
   with (parts/str(i)).open('rb') as src:
    while c:=src.read(1048576):out.write(c)
 assert tmp.stat().st_size==f['bytes'] and digest(tmp)==f['sha256'],'SHA256 mismatch '+str(p)
 tmp.replace(p);print('verified',f['path'],flush=True)
 if os.environ.get('COHEAR_KEEP_DOWNLOAD_PARTS')!='1':
  for q in parts.iterdir():q.unlink()
  parts.rmdir()

if __name__=='__main__':
 manifest=json.loads((ROOT/'Resources/ASRModels.json').read_text())
 for f in manifest['files']:download(f)
 print('全部ASR模型校验完成',flush=True)
