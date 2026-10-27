import importlib.metadata as md,pathlib,shutil,json
ROOT=pathlib.Path(__file__).resolve().parent.parent
out=ROOT/'.build/asr-licenses';out.mkdir(exist_ok=True)
for p in (ROOT/'Resources/ASRLicenses').glob('*'):
 if p.is_file():shutil.copy2(p,out/p.name)
for d in md.distributions():
 name=d.metadata.get('Name','unknown')
 for item in d.files or []:
  if item.name.lower().startswith(('license','copying','notice','authors')):
   p=pathlib.Path(d.locate_file(item))
   if p.is_file():
    dest=out/name/str(item).split('.dist-info/')[-1]
    dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,dest)
(out/'MODELS.txt').write_text('Paraformer ONNX INT8: Apache-2.0, FunASR / sherpa-onnx conversion.\nQwen3-ASR-1.7B-8bit: Apache-2.0, Qwen / mlx-community conversion.\nSilero VAD: MIT, Silero Team.\nModel sources, pinned revisions and file hashes: Contents/Resources/ASRModels.json\n')
shutil.copy2(ROOT/'Resources/ASRLicenses/sherpa-onnx-APACHE.txt',out/'MODELS-APACHE-2.0.txt')

for model in ['Sortformer','QwenAligner']:
    card=ROOT/'.models/ASR'/model/'README.md'
    if card.exists():shutil.copy2(card,out/(model+'-model-card.md'))
(out/'SPEAKER-MODELS.txt').write_text('Sortformer MLX conversion: mlx-community/diar_streaming_sortformer_4spk-v2.1-fp16\nOriginal model and upstream terms: https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1\nForced alignment: mlx-community/Qwen3-ForcedAligner-0.6B-8bit, upstream Qwen/Qwen3-ForcedAligner-0.6B (Apache-2.0).\nFull pinned file sources and hashes are in ASRModels.json.\n')
