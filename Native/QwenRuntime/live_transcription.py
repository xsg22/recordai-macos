"""Bounded online PCM transcription. Uses the already installed local ASR weights.

Audio arrives during capture; rolling hypotheses are emitted before input ends.
A dedicated reader keeps capture independent of model latency. Pauses close the
current phrase without inventing audio time. Only finalized phrases accumulate.
"""
import json
import math
import pathlib
import queue
import struct
import sys
import threading
import time

RATE = 16000
MAX_FRAME = 64000
MAX_BACKLOG = RATE * 20
MIN_SPEECH = int(RATE * .35)
UPDATE_SAMPLES = int(RATE * 1.25)
END_SILENCE = int(RATE * .65)
MAX_PHRASE = RATE * 12


def read_exact(stream, size):
    out = bytearray()
    while len(out) < size:
        block = stream.read(size - len(out))
        if not block:
            if not out:
                return None
            raise ValueError('Truncated live audio frame')
        out.extend(block)
    return bytes(out)


def pcm_frames(stream):
    while True:
        header = read_exact(stream, 4)
        if header is None:
            return
        count = struct.unpack('<I', header)[0]
        if not 0 < count <= MAX_FRAME:
            raise ValueError('Invalid live audio frame size')
        data = read_exact(stream, count * 4)
        if data is None:
            raise ValueError('Missing live audio frame')
        yield data


class OnlinePhrases:
    """Audio-time bounds and endpoint state; the injected decoder never sees silence-only input."""
    def __init__(self, decode, emit, np):
        self.decode, self.emit, self.np = decode, emit, np
        self.cursor = 0
        self.start = None
        self.chunks = []
        self.length = self.last_voice = self.last_update = self.voiced = 0
        self.last_text = ''
        self.preroll = np.empty(0, dtype=np.float32)

    def push(self, pcm):
        np = self.np
        data = np.frombuffer(pcm, dtype='<f4').copy()
        if not np.isfinite(data).all():
            raise ValueError('Non-finite live audio samples')
        # Do not ask an autoregressive model to transcribe silent windows.
        speaking = float(np.mean(data * data)) > .000009
        begin = self.cursor
        self.cursor += len(data)
        if self.start is None:
            if not speaking:
                self.preroll = np.concatenate((self.preroll, data))[-int(.2 * RATE):]
                return
            self.start = begin - len(self.preroll)
            self.chunks = [self.preroll, data]
            self.length = len(self.preroll) + len(data)
            self.preroll = np.empty(0, dtype=np.float32)
        else:
            self.chunks.append(data)
            self.length += len(data)
        if speaking:
            self.voiced += len(data)
            self.last_voice = self.length
        endpoint = self.length - self.last_voice >= END_SILENCE
        bounded = self.length >= MAX_PHRASE
        if endpoint or bounded:
            self.flush()
        elif self.voiced >= MIN_SPEECH and self.length - self.last_update >= UPDATE_SAMPLES:
            self.hypothesis(False)

    def hypothesis(self, final):
        if self.start is None or self.voiced < MIN_SPEECH:
            return
        np = self.np
        end = min(self.length, self.last_voice + int(.15 * RATE))
        audio = np.concatenate(self.chunks)[:end]
        text = self.decode(audio).strip()
        self.last_update = self.length
        if text and (final or text != self.last_text):
            self.emit('commit' if final else 'partial', text, self.start / RATE, (self.start + end) / RATE)
            self.last_text = text

    def flush(self):
        self.hypothesis(True)
        self.start = None
        self.chunks = []
        self.length = self.last_voice = self.last_update = self.voiced = 0
        self.last_text = ''
        self.preroll = self.np.empty(0, dtype=self.np.float32)


def run_live(model_path, language, hints_path=None):
    import numpy as np
    import mlx.core as mx
    from mlx_audio.stt import load
    from language_policy import recognition_language
    selected = recognition_language(language)
    if selected is None:
        raise ValueError('A live language must be explicit')
    words = []
    if hints_path:
        words = json.loads(pathlib.Path(hints_path).read_text()).get('words', [])
        if not isinstance(words, list) or len(words) > 32 or any(not isinstance(w, str) or not 2 <= len(w) <= 40 or '\n' in w or '\r' in w for w in words):
            raise ValueError('Invalid live hotwords')
    messages = queue.Queue()
    guard = threading.Lock()
    backlog = 0

    def reader():
        nonlocal backlog
        try:
            for data in pcm_frames(sys.stdin.buffer):
                count = len(data) // 4
                with guard:
                    backlog += count
                    if backlog > MAX_BACKLOG:
                        raise ValueError('Live transcription fell behind capture; original audio is preserved')
                messages.put(('audio', data))
        except Exception as error:
            messages.put(('error', error))
        finally:
            messages.put(('end', None))

    def emit(kind, text='', start=0, end=0):
        print(json.dumps(dict(type=kind, text=text, start=start, end=end), ensure_ascii=False), flush=True)

    # Begin draining stdin before loading weights, without retaining unbounded audio.
    threading.Thread(target=reader, daemon=True).start()
    from inference_lock import exclusive
    from inference_policy import configure_memory
    configure_memory(mx)
    with exclusive():
        model = load(pathlib.Path(model_path).resolve(strict=True))
        mx.eval(model.parameters())

    def decode(audio):
        with exclusive():
            result = model.generate(audio=audio, language=selected, hotwords=words[-12:] or None,
                                    max_tokens=256, temperature=0, chunk_duration=15,
                                    min_chunk_duration=.1, repetition_penalty=1.05, verbose=False)
        if result.generation_tokens >= 256:
            raise ValueError('Live transcript limit reached; original audio is preserved')
        text = result.text
        mx.clear_cache()
        return text

    phrases = OnlinePhrases(decode, emit, np)
    emit('ready')
    last_input = time.monotonic()
    while True:
        try:
            kind, value = messages.get(timeout=.15)
        except queue.Empty:
            # Pausing capture produces no PCM. Commit the tail without adding
            # the wall-clock pause to recording timestamps.
            if time.monotonic() - last_input >= .75:
                phrases.flush()
            continue
        if kind == 'error':
            raise value
        if kind == 'end':
            phrases.flush()
            emit('done', end=phrases.cursor / RATE)
            return
        with guard:
            backlog -= len(value) // 4
        last_input = time.monotonic()
        phrases.push(value)
