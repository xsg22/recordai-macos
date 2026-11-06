#!/usr/bin/env python3
"""Run frozen Mac ASR/speaker/alignment business fixtures without modifying a library.

Fixtures are a JSON list: id, path, optional language/kind/durationSeconds/caseID.
All output/cache/temp roots are explicit. The runner comes from test-mac-regressions.
"""
import argparse,hashlib,json,os,re,signal,subprocess,time
from pathlib import Path

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['output-root','fixtures','runner','readiness','engine','model','app-cli','agent-root']:
        p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--hotwords',type=Path)
    p.add_argument('--deny-host-python',type=Path)
    args=p.parse_args();source=Path(__file__).resolve().parents[1]
    frozen=json.loads(args.readiness.read_text())['inputs']
    for name,digest in frozen.items():
        if name.startswith('Sources/')or name=='Tests/ASRWindowRealPipelineSmoke.swift':
            assert hashlib.sha256((source/name).read_bytes()).hexdigest()==digest,'Runner source changed: '+name
    fixtures=json.loads(args.fixtures.read_text());ids=[f['id']for f in fixtures]
    assert len(ids)==len(set(ids))and all(re.fullmatch(r'[A-Za-z0-9_.-]+',x)for x in ids)
    out=args.output_root.resolve();out.mkdir(parents=True,exist_ok=False)
    for name in ['tmp','cache']:(out/name).mkdir()
    cli=[str(args.app_cli),'--root',str(args.agent_root)]
    def status():return json.loads(subprocess.check_output(cli+['status'],text=True))
    def space():
        v=os.statvfs('/');return v.f_bavail*v.f_frsize
    deny='(deny file-read* (subpath "/opt/homebrew"))'
    if args.deny_host_python:deny+='(deny file-read* (subpath '+json.dumps(str(args.deny_host_python.resolve()))+'))'
    policy='(version 1)(allow default)(deny network*)'+deny
    results=[]
    for fixture in fixtures:
        state=status();assert state.get('available')and not any(state[k]for k in ['recording','busy','preparing'])
        assert space()>8*1024**3,'System free space below 8GiB'
        directory=out/fixture['id'];directory.mkdir();language=fixture.get('language','zh')
        cmd=['/usr/bin/sandbox-exec','-p',policy,str(args.runner),str(directory),fixture['path'],str(args.model),str(args.engine),'360'if language=='en'else'480',language]
        env=dict(os.environ,TMPDIR=str(out/'tmp')+'/',XDG_CACHE_HOME=str(out/'cache'),TALKTUCK_REGRESSION_CASE='real-window-pipeline',HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1',PYTHONDONTWRITEBYTECODE='1')
        if args.hotwords:env['TALKTUCK_TEST_HOTWORDS_JSON']=str(args.hotwords)
        started=time.monotonic();minimum=space();reason=None
        print('START '+fixture['id'],flush=True)
        with (directory/'test.log').open('x')as log:
            child=subprocess.Popen(cmd,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
            while child.poll()is None:
                time.sleep(2)
                if child.poll()is not None:break
                active=status();minimum=min(minimum,space())
                if not active.get('available')or any(active.get(k)for k in ['recording','preparing','busy']):reason='INTERRUPTED_APP_WORK'
                elif minimum<8*1024**3:reason='ABORT_SYSTEM_RESERVE'
                elif time.monotonic()-started>1200:reason='TIMEOUT'
                if reason:
                    os.killpg(child.pid,signal.SIGTERM)
                    try:child.wait(timeout=10)
                    except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.wait()
                    break
        report=dict(caseID=fixture.get('caseID',fixture['id']),fixtureID=fixture['id'],status=reason or ('PASS'if child.returncode==0 else'FAIL'),exitCode=child.returncode,seconds=time.monotonic()-started,engineSHA256=hashlib.sha256(args.engine.read_bytes()).hexdigest(),minimumSystemFreeBytes=minimum,readiness=str(args.readiness),command=cmd,kind=fixture.get('kind','provided audio fixture'),networkAndHostPythonDenied=True,userLibraryModified=False,hardwareCapture=False)
        (directory/'driver.json').write_text(json.dumps(report,indent=2));results.append(report)
        (out/'summary.json').write_text(json.dumps(results,indent=2));print('DONE '+fixture['id']+' '+report['status'],flush=True)
        if reason:break
    assert len(results)==len(fixtures)and all(x['status']=='PASS'for x in results),'Incomplete or failed real-fixture run'
if __name__=='__main__':main()
