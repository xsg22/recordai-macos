#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .tools .vendor .build
python3 Scripts/prepare-asr-runtime.py
xcrun clang++ -std=c++17 -O3 -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=14.0 \
    -I .vendor/sherpa-runtime/sherpa_onnx/include Native/paraformer-live.cpp \
    -L .vendor/sherpa-runtime/sherpa_onnx/lib -lsherpa-onnx-c-api \
    -Wl,-rpath,@executable_path -framework AudioToolbox -framework CoreFoundation -o .build/paraformer-live
python3 Scripts/build-qwen-runtime.py

.tools/asr-venv/bin/python Scripts/collect-asr-licenses.py
