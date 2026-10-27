#!/usr/bin/env python3
import hashlib,json,pathlib,subprocess,sys
ROOT=pathlib.Path(__file__).resolve().parent.parent
venv=ROOT/'.tools/asr-venv';python=venv/'bin/python'
lock=ROOT/'Native/QwenRuntime/requirements.lock'
if sys.version_info[:2] != (3,12):raise SystemExit('构建Qwen隔离组件需要Python 3.12；最终用户无需安装Python')
if not lock.exists():raise SystemExit('缺少已经验收的Qwen运行时依赖清单')
if not python.exists():subprocess.run([sys.executable,'-m','venv',str(venv)],check=True)
requirements_hash=hashlib.sha256(lock.read_bytes()).hexdigest()
marker=venv/'.cohear-lock-sha256'
if not marker.exists() or marker.read_text()!=requirements_hash:
    subprocess.run([str(python),'-m','pip','install','--disable-pip-version-check','-r',str(lock)],check=True)
    marker.write_text(requirements_hash)
source=ROOT/'Native/QwenRuntime/worker.py'
stamp=ROOT/'.build/qwen-runtime/.source-sha256'
version=hashlib.sha256(source.read_bytes()+(ROOT/'Native/QwenRuntime/speaker_attribution.py').read_bytes()+lock.read_bytes()+(ROOT/'Scripts/qwen-runtime.spec').read_bytes()).hexdigest()
if stamp.exists() and stamp.read_text()==version and (ROOT/'.build/qwen-runtime/qwen-asr/qwen-asr').exists():
    print('复用已构建的Qwen3-ASR隔离运行时');sys.exit(0)
subprocess.run([str(python),'-m','PyInstaller','--noconfirm','--clean','--distpath',str(ROOT/'.build/qwen-runtime'),
                '--workpath',str(ROOT/'.build/qwen-freezer'),str(ROOT/'Scripts/qwen-runtime.spec')],check=True,cwd=ROOT)
stamp.write_text(version)
