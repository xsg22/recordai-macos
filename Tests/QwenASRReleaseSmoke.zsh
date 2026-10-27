#!/bin/zsh
set -euo pipefail
cp .build/paraformer-live .build/qwen-runtime/qwen-asr/
cp .vendor/sherpa-runtime/sherpa_onnx/lib/{libsherpa-onnx-c-api.dylib,libonnxruntime.dylib} .build/qwen-runtime/qwen-asr/
.build/new-engine-smoke "$PWD/.build/qwen-runtime/qwen-asr/qwen-asr" "$PWD/.models/ASR/Qwen3ASR" "$PWD/.tools/chinese.aiff" "$PWD/.tools/qwen-engine-output"
.build/new-append-smoke "$PWD/.build/qwen-runtime/qwen-asr/qwen-asr" "$PWD/.models/ASR/Qwen3ASR" "$PWD/.tools/chinese.aiff"
.build/qwen-runtime/qwen-asr/qwen-asr .models/ASR/Qwen3ASR .tools/genuine-phrases-clips/segments.json zh .tools/genuine-phrases-result.json
.build/qwen-runtime/qwen-asr/qwen-asr .models/ASR/Qwen3ASR .tools/silent-clips/segments.json zh .tools/silent-result.json
python3 - <<'PY'
import json
j=json.load(open('.tools/genuine-phrases-result.json'));text=''.join(x['text'] for x in j['segments']);print(text)
assert '谢谢观看' in text and '字幕组' in text,'真实说出的词不能被盲删'
assert json.load(open('.tools/silent-result.json'))['segments']==[]
print('PASS: 真正说出的谢谢观看/字幕组被保留，四秒纯静音没有进入Qwen，完整中文与两段续录通过。')
PY
