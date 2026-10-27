"""使用合成中文音频按实时速率送入，不接触用户麦克风或个人会议。"""
import json
import pathlib
import struct
import subprocess
import sys
import threading
import time

engine, model, pcm, output = sys.argv[1:]
raw = pathlib.Path(pcm).read_bytes()
events = []
eof_sent = threading.Event()
started = time.monotonic()
with open(output + '.engine.log', 'wb') as log:
    process = subprocess.Popen([engine, model, 'zh'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
    ready = threading.Event()
    def read():
        for line in process.stdout:
            event = json.loads(line)
            event['elapsed'] = round(time.monotonic() - started, 3)
            event['before_eof'] = not eof_sent.is_set()
            events.append(event)
            if event['type'] == 'ready': ready.set()
    reader = threading.Thread(target=read)
    reader.start()
    assert ready.wait(30), '模型未就绪'
    stride = 1600 * 4
    next_frame = time.monotonic()
    for offset in range(0, len(raw), stride):
        frame = raw[offset:offset + stride]
        process.stdin.write(struct.pack('<I', len(frame) // 4) + frame)
        process.stdin.flush()
        next_frame += len(frame) / (16000 * 4)
        time.sleep(max(0, next_frame - time.monotonic()))
    eof_sent.set()
    process.stdin.close()
    assert process.wait(timeout=30) == 0, 'worker失败'
    reader.join(5)
assert any(e['type'] == 'partial' and e['text'].strip() and e['before_eof'] for e in events), '停止前未输出实时文本'
assert any(e['type'] == 'commit' and any('\u4e00' <= c <= '\u9fff' for c in e['text']) for e in events), '未输出中文提交片段'
assert events[-1]['type'] == 'done', '没有正确结束'
assert len([e for e in events if e['type'] == 'ready']) == 1, '模型重复加载'
pathlib.Path(output).write_text(json.dumps(events, ensure_ascii=False, indent=2))
first = next(e for e in events if e['type'] == 'partial' and e['text'].strip())
ready_event = next(e for e in events if e['type'] == 'ready')
latency = first['elapsed'] - ready_event['elapsed']
assert latency < 5, f'模型就绪后首段实时预览延迟过高: {latency}'
print(f"PASS: 停止前已输出中文partial；模型只加载一次；尾段commit/done；模型加载{ready_event['elapsed']}秒，就绪后首段{latency:.3f}秒。")
print('\n'.join(e['text'] for e in events if e['type'] == 'commit'))

# 纯静音必须跳过识别，不能生成字幕幻觉；只使用人工生成零样本。
silent = subprocess.run([engine, model, 'zh'], input=struct.pack('<I', 48000) + bytes(48000 * 4),
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30)
silent_events = [json.loads(line) for line in silent.stdout.splitlines()]
assert silent.returncode == 0 and silent_events[-1]['type'] == 'done'
assert all(not e['text'].strip() for e in silent_events), '静音产生了幻觉文字'
print('PASS: 3秒合成静音无幻觉，尾段正常结束。')
