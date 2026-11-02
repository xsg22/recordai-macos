#!/usr/bin/env python3
"""Download public RecordAI release assets with resumable ranges and independent GitHub SHA256 checks."""
import argparse
import concurrent.futures
import datetime
import hashlib
import json
from pathlib import Path
import re
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('tag')
parser.add_argument('--destination', type=Path, required=True)
parser.add_argument('--report', type=Path, required=True)
parser.add_argument('--metadata', type=Path, help='Release JSON read through an authenticated GitHub connection; avoids anonymous API limits')
args = parser.parse_args()
match = re.fullmatch(r'v(\d+\.\d+\.\d+)-functional\.[1-9][0-9]*',args.tag)
if not match: parser.error('Expected a RecordAI functional release tag')
version = match[1]
dest = args.destination.resolve(); dest.mkdir(parents=True,exist_ok=True)
api = 'https://api.github.com/repos/xsg22/recordai-macos/releases/tags/'+args.tag
direct = urllib.request.build_opener(urllib.request.ProxyHandler({}))
standard = urllib.request.build_opener()

def request(url, headers=None, alternate=False):
    # A configured system proxy and direct HTTPS can have different reachability on this Mac.
    # Keep TLS verification enabled on both routes; never modify the user's proxy settings.
    routes = (direct,standard) if alternate else (standard,direct)
    for index, opener in enumerate(routes):
        try:
            return opener.open(urllib.request.Request(url,headers={
                'User-Agent':'RecordAI-release-verification',**(headers or {})}),timeout=25)
        except (OSError,TimeoutError):
            if index == len(routes)-1: raise

if args.metadata:
    release = json.loads(args.metadata.read_text(encoding='utf-8'))
else:
    with request(api,alternate=True) as response: release = json.load(response)
assert release['tag_name'] == args.tag and not release['draft']
assert release['html_url'] == 'https://github.com/xsg22/recordai-macos/releases/tag/'+args.tag
assets = {asset['name']:asset for asset in release['assets']}
names = [f'RecordAI-{version}-arm64.{ext}' for ext in ['dmg','dmg.sha256','pkg','pkg.sha256']]
assert all(name in assets for name in names),'Missing release assets'
assert all(assets[name]['browser_download_url'] == f'https://github.com/xsg22/recordai-macos/releases/download/{args.tag}/{name}' for name in names)
digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()

def verify(path):
    meta = assets[path.name]
    assert meta['size'] == path.stat().st_size
    assert meta['digest'] == 'sha256:'+digest(path),'Downloaded bytes differ from GitHub asset digest'

def fetch(extension):
    name = f'RecordAI-{version}-arm64.{extension}'
    meta = assets[name]; final = dest/name
    with request(assets[name+'.sha256']['browser_download_url']) as response: checksum = response.read()
    expected, filename = checksum.decode().split()
    assert filename == name and re.fullmatch('[0-9a-f]{64}',expected)
    assert meta['digest'] == 'sha256:'+expected
    (dest/(name+'.sha256')).write_bytes(checksum); verify(dest/(name+'.sha256'))
    if final.is_file() and digest(final) == expected:
        verify(final); return
    total = meta['size']; chunks = dest/(extension+'-chunks'); chunks.mkdir(exist_ok=True)
    tasks = [(start,min(start+4*1024*1024-1,total-1)) for start in range(0,total,4*1024*1024)]
    def chunk(bounds):
        start,end = bounds; path = chunks/str(start)
        if path.is_file() and path.stat().st_size == end-start+1: return
        for attempt in range(4):
            try:
                with request(meta['browser_download_url'],{'Range':f'bytes={start}-{end}'},alternate=bool(attempt%2)) as response:
                    assert response.status == 206 and response.headers['Content-Range'] == f'bytes {start}-{end}/{total}'
                    data = response.read()
                assert len(data) == end-start+1
                path.write_bytes(data); return
            except Exception:
                if attempt == 3: raise
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool: list(pool.map(chunk,tasks))
    partial = final.with_name(final.name+'.partial')
    with partial.open('wb') as stream:
        for start,_ in tasks:
            assert stream.tell() == start; stream.write((chunks/str(start)).read_bytes())
    assert partial.stat().st_size == total and digest(partial) == expected
    partial.replace(final); verify(final)
    for start,_ in tasks: (chunks/str(start)).unlink()
    chunks.rmdir()
    print('Verified',name,total,flush=True)

with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool: list(pool.map(fetch,['dmg','pkg']))
report = dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),releaseTag=args.tag,
              releaseURL=release['html_url'],allFourDownloaded=True,checksumFilesMatchPackages=True,
              allFourMatchGitHubDigest=True,assets=[dict(name=name,bytes=(dest/name).stat().st_size,
              sha256=digest(dest/name),url=assets[name]['browser_download_url']) for name in names])
args.report.parent.mkdir(parents=True,exist_ok=True)
args.report.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
print('PASS: four actual GitHub asset downloads, package checksums and independent GitHub digests')
