# -*- mode: python ; coding: utf-8 -*-
from PyInstaller.utils.hooks import collect_all, collect_submodules, copy_metadata, collect_data_files
from pathlib import Path
root=Path(SPECPATH).parent
mlx_data,mlx_binaries,mlx_hidden=collect_all('mlx')
# Qwen模型通过类型名动态导入，只封装本次使用的ASR模块。
hidden=mlx_hidden+collect_submodules('mlx_audio.stt.models.qwen3_asr')+collect_submodules('mlx_audio.vad.models.sortformer')+['mlx_audio.vad.utils', 'miniaudio',
 'mlx_audio.lm.sample_utils','transformers.models.qwen2.tokenization_qwen2',
 'transformers.models.whisper.feature_extraction_whisper','transformers.models.auto.tokenization_auto',
 'transformers.models.qwen2.tokenization_qwen2_fast']
datas=mlx_data+collect_data_files('mlx_audio',include_py_files=True,
 includes=['__init__.py','utils.py','audio_io.py','version.py','dsp.py','base.py','stt/**','lm/**','vad/**'])
for name in ['mlx','mlx-metal','mlx-audio','transformers','huggingface-hub','numpy','scipy','tokenizers','safetensors','tqdm','regex','packaging']:
 datas+=copy_metadata(name)
a=Analysis([str(root/'Native/QwenRuntime/worker.py')],pathex=[],binaries=mlx_binaries,datas=datas,
 hiddenimports=hidden,hookspath=[],hooksconfig={},runtime_hooks=[],
 excludes=['torch','torchvision','torchaudio','tensorflow','jax','matplotlib','pandas','IPython','pytest','mlx_audio.tts','mlx_audio.sts'],noarchive=False)
pyz=PYZ(a.pure)
exe=EXE(pyz,a.scripts,[],exclude_binaries=True,name='qwen-asr',debug=False,bootloader_ignore_signals=False,
 strip=False,upx=False,console=True,target_arch='arm64',codesign_identity=None,entitlements_file=None)
coll=COLLECT(exe,a.binaries,a.datas,strip=False,upx=False,name='qwen-asr')
