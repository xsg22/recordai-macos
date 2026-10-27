#!/usr/bin/env python3
"""从PyPI固定wheel提取C ABI库；无需目标用户安装Python。"""
import hashlib,json,pathlib,urllib.request,zipfile
ROOT=pathlib.Path(__file__).resolve().parent.parent
f=json.loads((ROOT/'Resources/ASRRuntime.json').read_text())['sherpa']
p=ROOT/'.tools'/f['filename']
if not p.exists() or hashlib.file_digest(p.open('rb'),'sha256').hexdigest()!=f['sha256']:
    op=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    temp=p.with_suffix('.partial')
    with op.open(f['url'],timeout=60) as r,temp.open('wb') as out:
        while c:=r.read(1048576):out.write(c)
    assert temp.stat().st_size==f['bytes'] and hashlib.file_digest(temp.open('rb'),'sha256').hexdigest()==f['sha256']
    temp.replace(p)
root=ROOT/'.vendor/sherpa-runtime';root.mkdir(exist_ok=True)
with zipfile.ZipFile(p) as z:
    for name in z.namelist():
        assert not pathlib.PurePosixPath(name).is_absolute() and '..' not in pathlib.PurePosixPath(name).parts
    z.extractall(root)
licenses=ROOT/'.build/asr-licenses';licenses.mkdir(parents=True,exist_ok=True)
for path in root.rglob('*'):
    if path.is_file() and ('license' in path.name.lower() or 'notice' in path.name.lower()):
        (licenses/('sherpa-'+path.name)).write_bytes(path.read_bytes())
print('sherpa-onnx 1.13.8 wheel SHA256 verified')
