#!/usr/bin/env python3
"""Verify whole-library sync with native adapters and an isolated loopback backend.
All generated files are placed in --output; requires already installed dependencies.
"""
import argparse, json, os, selectors, signal, subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--server-repo',type=Path,required=True)
p.add_argument('--node',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
p.add_argument('--simulator')
a=p.parse_args();mac=Path(__file__).resolve().parents[1];server=a.server_repo.resolve();run=a.output.resolve()
run.mkdir(parents=True,exist_ok=False)
for part in ['tmp','cache','sources','artifacts','build']:(run/part).mkdir()
env=dict(os.environ,TMPDIR=str(run/'tmp')+'/',XDG_CACHE_HOME=str(run/'cache'),SWIFT_USE_OLD_DRIVER='1',PYTHONDONTWRITEBYTECODE='1')
node=a.node.resolve();env['PATH']=str(node.parent)+os.pathsep+env['PATH']
def call(cmd,label,cwd=mac,timeout=600):
 with (run/'artifacts'/label).open('w') as out:subprocess.run([str(x) for x in cmd],cwd=cwd,env=env,stdout=out,stderr=subprocess.STDOUT,check=True,timeout=timeout)
for f in (mac/'Sources').glob('*.swift'):(run/'sources'/f.name).write_bytes(f.read_bytes())
f=run/'sources/CoHearTranscribeApp.swift';f.write_text(f.read_text().replace('@main\n',''))
base=['xcrun','swiftc','-swift-version','5','-parse-as-library','-target','arm64-apple-macosx14.0','-module-cache-path',run/'cache/swift',*sorted((run/'sources').glob('*.swift'))]
call(base+[mac/'Tests/LibraryAutomaticSyncSmoke.swift','-o',run/'build/mac-auto'],'mac-compile.log')
call(base+[mac/'Tests/TalkTuckAccountSmoke.swift','-o',run/'build/mac-account'],'account-compile.log')
call([node,'node_modules/typescript/bin/tsc','--noEmit'],'server-typecheck.log',server)
call([node,'node_modules/tsx/dist/cli.mjs','--test',server/'test/library-sync.test.ts',server/'test/library-audio.test.ts',server/'test/mac-account.test.ts'],'server-tests.log',server)
children=[]
def fixture(port,label):
 err=(run/'artifacts'/label).open('w')
 c=subprocess.Popen([str(node),'node_modules/tsx/dist/cli.mjs','test/support/mac-account-server.ts'],cwd=server,env=dict(env,SYNC_TEST_PORT=str(port),SYNC_TEST_AUDIO='1'),stdout=subprocess.PIPE,stderr=err,text=True,start_new_session=True);children.append((c,err))
 with selectors.DefaultSelector() as s:
  s.register(c.stdout,selectors.EVENT_READ)
  if not s.select(timeout=20):raise RuntimeError('Fixture startup timed out')
 endpoint=c.stdout.readline().strip()
 if endpoint!='http://127.0.0.1:'+str(port):raise RuntimeError('Unexpected fixture endpoint: '+endpoint)
 return endpoint
try:
 endpoint=fixture(39043,'fixture.log')
 call([run/'build/mac-auto',endpoint,run/'build/mac-data'],'mac-auto.log')
 call([run/'build/mac-account',endpoint],'mac-account.log')
 if a.simulator:
  import sys
  sys.path.insert(0,str(server.parent/'app/scripts'))
  from test_project_snapshot import freeze_phone_project
  project=freeze_phone_project(server.parent/'app',run/'build/phone-project')
  fixture(39044,'audio-fixture.log')
  cases=['LibrarySyncBridgeTests','LibraryAudioTests','RecordingDomainTests','LibraryIntegrityTests','LocalizationTests']
  # The two bridge tests require the separate Mac seed/conflict script and are exercised there.
  call(['xcodebuild','test','-project',project,'-scheme','VoiceNotesLogicTests','-destination','platform=iOS Simulator,id='+a.simulator,'-derivedDataPath',run/'build/ios','-clonedSourcePackagesDirPath',run/'cache/packages','-parallel-testing-enabled','NO','CODE_SIGNING_ALLOWED=NO','-resultBundlePath',run/'artifacts/phone.xcresult',*[f'-only-testing:VoiceNotesTests/{x}' for x in cases],'-skip-testing:VoiceNotesTests/LibrarySyncBridgeTests/testBridgeDownloadMacTextModifyGroupAndIsolateAccount','-skip-testing:VoiceNotesTests/LibrarySyncBridgeTests/testBridgeResolvedMacTextArrives'],'phone.log',server.parent,1200)
  summary=json.loads(subprocess.check_output(['xcrun','xcresulttool','get','test-results','summary','--path',str(run/'artifacts/phone.xcresult')],env=env))
  (run/'artifacts/phone-summary.json').write_text(json.dumps(summary,indent=2))
  assert summary['failedTests']==0 and summary['passedTests']>0,summary
 (run/'result.json').write_text(json.dumps({'status':'PASS','backend':'isolated loopback SQLite, synthetic accounts and audio','mac':'automatic enrollment, original audio, pause, restart, account isolation, cached offline login','simulator':a.simulator,'productionModified':False},indent=2))
 print('PASS. Evidence: '+str(run))
finally:
 for child,err in children:
  if child.poll() is None:os.killpg(child.pid,signal.SIGTERM)
  child.wait(timeout=15);err.close()
