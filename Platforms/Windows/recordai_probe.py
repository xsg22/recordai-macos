"""Windows feasibility probes. No app/library writes; capture and model downloads are opt-in."""
from __future__ import annotations

import argparse
import array
import datetime
import hashlib
import importlib.metadata
import json
import math
import multiprocessing
import os
from pathlib import Path
import platform
import queue
import re
import sys
import time
import unicodedata
import uuid
import wave


def timestamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def file_digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def write_report(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.partial')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n', encoding='utf-8')
    temporary.replace(path)


def host_info():
    versions = {}
    for package in ['PyAudioWPatch', 'faster-whisper', 'ctranslate2', 'qwen-asr', 'torch', 'transformers']:
        try:
            versions[package] = importlib.metadata.version(package)
        except importlib.metadata.PackageNotFoundError:
            versions[package] = None
    return dict(schemaVersion=1, observedAt=timestamp(), platform=platform.system(),
                osVersion=platform.version(), architecture=platform.machine(), python=platform.python_version(),
                cpuCount=os.cpu_count(), packages=versions)


def audio_stats(path):
    with wave.open(str(path), 'rb') as reader:
        channels, width, rate, frames = reader.getnchannels(), reader.getsampwidth(), reader.getframerate(), reader.getnframes()
        if width != 2 or channels < 1 or rate <= 0:
            raise ValueError('The validation input must be PCM16 WAV with a positive sample rate.')
        count = 0; squared = 0; peak = 0
        while data := reader.readframes(8192):
            samples = array.array('h', data)
            if sys.byteorder != 'little':
                samples.byteswap()
            count += len(samples)
            squared += sum(sample * sample for sample in samples)
            peak = max(peak, max((abs(sample) for sample in samples), default=0))
    if count != frames * channels:
        raise ValueError('The WAV data is truncated and does not match its frame count.')
    return dict(channels=channels, sampleRate=rate, frames=frames, duration=frames / rate,
                rms=math.sqrt(squared / count) / 32768 if count else 0, peak=peak / 32768,
                signalDetected=peak > 3, sha256=file_digest(path))


def device_record(device):
    return {key: device.get(key) for key in ['index', 'name', 'hostApi', 'maxInputChannels',
            'maxOutputChannels', 'defaultSampleRate', 'isLoopbackDevice']}


def inspect_devices():
    report = host_info()
    report.update(hardwareCaptureValidated=False, status='unsupported', devices=[])
    if platform.system() != 'Windows':
        report['reason'] = 'WASAPI probing requires a native Windows process.'
        return report
    try:
        import pyaudiowpatch as audio
        with audio.PyAudio() as manager:
            wasapi = manager.get_host_api_info_by_type(audio.paWASAPI)
            devices = [device_record(d) for d in manager.get_device_info_generator() if d['hostApi'] == wasapi['index']]
            try:
                microphone = device_record(manager.get_device_info_by_index(int(wasapi['defaultInputDevice'])))
            except (OSError, ValueError):
                microphone = None
            try:
                loopback = device_record(manager.get_default_wasapi_loopback())
            except (OSError, ValueError):
                loopback = None
            report.update(status='inspected', devices=devices, defaultMicrophone=microphone, defaultLoopback=loopback, wasapiHostIndex=wasapi['index'])
            if not devices:
                report.update(status='unavailable', reason='No WASAPI audio devices were found.')
    except ImportError:
        report.update(status='missing_dependency', reason='Install requirements-capture.txt in the validation environment.')
    except (OSError, ValueError) as error:
        report.update(status='unavailable', reason=str(error))
    return report


def capture_track(device, seconds, path, start_event, ready, results):
    """A separate process bounds driver stalls and preserves completed original track data."""
    path = Path(path); partial = path.with_name(path.stem + '.partial.wav')
    result = dict(device=device, status='failed', path=str(partial))
    try:
        import pyaudiowpatch as audio
        with audio.PyAudio() as manager:
            current = manager.get_device_info_by_index(int(device['index']))
            if current['name'] != device['name'] or current['hostApi'] != device['hostApi']:
                raise RuntimeError('The selected device changed before capture. Select it again.')
            channels = min(2, int(current['maxInputChannels']))
            rate = int(current['defaultSampleRate'])
            if channels < 1 or rate <= 0:
                raise RuntimeError('The selected device has no usable input channels.')
            stream = manager.open(format=audio.paInt16, channels=channels, rate=rate, input=True,
                                  input_device_index=int(device['index']), frames_per_buffer=1024, start=False)
            try:
                ready.put(str(path))
                if not start_event.wait(15):
                    raise TimeoutError('Capture was not started because another device was unavailable.')
                started = time.monotonic(); stream.start_stream()
                remaining = int(rate * seconds)
                with wave.open(str(partial), 'wb') as writer:
                    writer.setnchannels(channels); writer.setsampwidth(2); writer.setframerate(rate)
                    while remaining:
                        requested = min(1024, remaining)
                        data = stream.read(requested, exception_on_overflow=True)
                        if len(data) != requested * channels * 2:
                            raise RuntimeError('Audio input returned incomplete frames.')
                        # Patch WAV lengths after each write so a terminated driver cannot hide received samples.
                        writer.writeframes(data); remaining -= requested
                result.update(startMonotonic=started, elapsed=time.monotonic() - started)
            finally:
                if stream.is_active():
                    stream.stop_stream()
                stream.close()
        partial.replace(path)
        stats = audio_stats(path)
        result.update(status='captured' if stats['signalDetected'] else 'needs_signal', path=str(path), audio=stats)
    except Exception as error:
        result['error'] = str(error)
    results.put(result)


def capture(args):
    report = inspect_devices()
    report.update(kind='capture', requestedSeconds=args.seconds, source=args.source, mixingValidated=False)
    if report['status'] != 'inspected':
        return report
    try:
        import pyaudiowpatch as audio
        with audio.PyAudio() as manager:
            selected = []
            for kind, flag, default in [('microphone', args.microphone, report.get('defaultMicrophone')),
                                        ('system', args.loopback, report.get('defaultLoopback'))]:
                if args.source not in [kind, 'both']:
                    continue
                device = device_record(manager.get_device_info_by_index(flag)) if flag is not None else default
                if not device or not device.get('maxInputChannels'):
                    raise RuntimeError('No usable ' + kind + ' device. This is not a passed capture check.')
                if device['hostApi'] != report['wasapiHostIndex']:
                    raise ValueError('Select a WASAPI device for this capture probe.')
                if kind == 'system' and not device.get('isLoopbackDevice'):
                    raise ValueError('--loopback must select a WASAPI loopback input, not an output endpoint.')
                if kind == 'microphone' and device.get('isLoopbackDevice'):
                    raise ValueError('A microphone source cannot be a loopback device.')
                selected.append((kind, device))
        run = Path(args.output).resolve().parent / ('capture-' + uuid.uuid4().hex)
        run.mkdir()
        context = multiprocessing.get_context('spawn')
        event, ready, results = context.Event(), context.Queue(), context.Queue()
        processes = [context.Process(target=capture_track, args=(device, args.seconds, run / (kind + '.wav'), event, ready, results)) for kind, device in selected]
        for process in processes:
            process.start()
        try:
            for _ in processes:
                ready.get(timeout=12)
            event.set()
            deadline = time.monotonic() + args.seconds + 15
            tracks = [results.get(timeout=max(.1, deadline - time.monotonic())) for _ in processes]
            report.update(tracks=tracks, originalTracks=str(run), status='captured' if all(t['status'] == 'captured' for t in tracks) else 'incomplete')
            report['hardwareCaptureValidated'] = report['status'] == 'captured'
        except queue.Empty:
            report.update(status='timeout', reason='A device failed to open or stopped delivering frames. Partial tracks are preserved.', originalTracks=str(run))
        finally:
            for process in processes:
                process.join(timeout=1)
                if process.is_alive():
                    process.terminate(); process.join(timeout=3)
            ready.close(); results.close()
    except Exception as error:
        report.update(status='failed', reason=str(error))
    return report


def edit_distance(reference, hypothesis):
    previous = list(range(len(hypothesis) + 1))
    for i, expected in enumerate(reference, 1):
        current = [i]
        for j, actual in enumerate(hypothesis, 1):
            current.append(min(previous[j] + 1, current[-1] + 1, previous[j - 1] + (expected != actual)))
        previous = current
    return previous[-1]


def quality(reference, hypothesis):
    normalize = lambda text: ''.join(c.casefold() for c in unicodedata.normalize('NFKC', text) if unicodedata.category(c)[0] in 'LN')
    a, b = normalize(reference), normalize(hypothesis)
    words = lambda text: re.findall(r"[^\W_]+(?:['’][^\W_]+)*", unicodedata.normalize('NFKC', text).casefold())
    wa, wb = words(reference), words(hypothesis)
    return dict(characterErrorRate=edit_distance(a, b) / len(a) if a else None,
                wordErrorRate=edit_distance(wa, wb) / len(wa) if wa else None,
                referenceCharacters=len(a), referenceWords=len(wa))


def validate_segments(segments, duration):
    previous = 0.
    for segment in segments:
        start, end = segment['start'], segment['end']
        if not all(math.isfinite(x) for x in [start, end]) or not 0 <= start <= end <= duration + .5 or start < previous - .2:
            raise ValueError('Invalid or non-monotonic transcription timestamps.')
        word_previous = start
        for word in segment.get('words', []):
            a, b = word['start'], word['end']
            if not all(math.isfinite(x) for x in [a, b]) or not max(0, start - .5) <= a <= b <= end + .5 or a < word_previous - .2:
                raise ValueError('Invalid or non-monotonic word timestamps.')
            word_previous = a
        previous = start


def peak_memory_bytes():
    try:
        if platform.system() == 'Windows':
            import ctypes
            from ctypes import wintypes
            class Counters(ctypes.Structure):
                _fields_ = [('cb', wintypes.DWORD), ('PageFaultCount', wintypes.DWORD)] + [(name, ctypes.c_size_t) for name in
                    ['PeakWorkingSetSize', 'WorkingSetSize', 'QuotaPeakPagedPoolUsage', 'QuotaPagedPoolUsage',
                     'QuotaPeakNonPagedPoolUsage', 'QuotaNonPagedPoolUsage', 'PagefileUsage', 'PeakPagefileUsage']]
            counters = Counters(); counters.cb = ctypes.sizeof(counters)
            kernel = ctypes.WinDLL('kernel32'); kernel.GetCurrentProcess.restype = wintypes.HANDLE
            psapi = ctypes.WinDLL('psapi')
            psapi.GetProcessMemoryInfo.argtypes = [wintypes.HANDLE, ctypes.POINTER(Counters), wintypes.DWORD]
            if not psapi.GetProcessMemoryInfo(kernel.GetCurrentProcess(), ctypes.byref(counters), counters.cb):
                return None
            return counters.PeakWorkingSetSize
        import resource
        value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        return value if platform.system() == 'Darwin' else value * 1024
    except (ImportError, OSError, AttributeError):
        return None


def transcribe(args):
    report = host_info()
    report.update(kind='engine', engine=args.engine, device=args.device, model=str(args.model),
                  hardwareCaptureValidated=False, speakerAnalysisValidated=False, status='failed')
    try:
        source = Path(args.input).resolve(strict=True); stats = audio_stats(source)
        if stats['duration'] <= 0:
            raise ValueError('The audio file contains no frames.')
        if not args.allow_download and not Path(args.model).is_dir():
            raise ValueError('Use a local model directory, or explicitly pass --allow-download for model weights.')
        if not args.allow_download:
            os.environ['HF_HUB_OFFLINE'] = '1'; os.environ['TRANSFORMERS_OFFLINE'] = '1'
        started = time.perf_counter()
        language = None if args.language == 'auto' else args.language
        if args.engine == 'faster-whisper':
            from faster_whisper import WhisperModel
            model = WhisperModel(args.model, device=args.device, compute_type='int8' if args.device == 'cpu' else 'float16', local_files_only=not args.allow_download)
            rows, info = model.transcribe(str(source), language=language, task='transcribe', beam_size=5, word_timestamps=True)
            segments = [dict(start=row.start, end=row.end, text=row.text,
                        words=[dict(start=w.start, end=w.end, text=w.word) for w in row.words or []]) for row in rows]
            detected, timestamp_source = info.language, 'model'
        else:
            import torch
            from qwen_asr import Qwen3ASRModel
            model = Qwen3ASRModel.from_pretrained(args.model, dtype=torch.float32 if args.device == 'cpu' else torch.float16,
                                                device_map='cpu' if args.device == 'cpu' else 'cuda:0')
            output = model.transcribe(audio=str(source), language={'en': 'English', 'zh': 'Chinese'}.get(args.language))
            segments = [dict(start=0., end=stats['duration'], text=output[0].text, words=[])]
            detected, timestamp_source = output[0].language, 'recording_bounds_not_alignment'
        elapsed = time.perf_counter() - started
        validate_segments(segments, stats['duration'])
        text = ''.join(row['text'] for row in segments)
        if not text.strip():
            raise ValueError('No speech recognized. This is not a passed speech-recognition check.')
        assert file_digest(source) == stats['sha256'], 'Input audio changed during inference.'
        report.update(status='transcribed', input=stats, requestedLanguage=args.language, detectedLanguage=detected,
                      text=text, segments=segments, timestampSource=timestamp_source,
                      peakProcessMemoryBytes=peak_memory_bytes(),
                      localModelBytes=sum(p.stat().st_size for p in Path(args.model).rglob('*') if p.is_file()) if Path(args.model).is_dir() else None,
                      processingSeconds=elapsed, realTimeFactor=elapsed / stats['duration'] if stats['duration'] else None,
                      nativeWindowsInferenceValidated=platform.system() == 'Windows')
        if args.reference:
            report['quality'] = quality(Path(args.reference).read_text(encoding='utf-8'), text)
    except Exception as error:
        report.update(status='failed', error=str(error))
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    devices = commands.add_parser('devices', help='Inspect devices only. Never records audio.')
    devices.add_argument('--output', type=Path, required=True)
    recording = commands.add_parser('capture', help='Explicitly capture local audio into a new isolated folder.')
    recording.add_argument('--source', choices=['microphone', 'system', 'both'], required=True)
    recording.add_argument('--seconds', type=float, default=10)
    recording.add_argument('--microphone', type=int)
    recording.add_argument('--loopback', type=int)
    recording.add_argument('--output', type=Path, required=True)
    engine = commands.add_parser('transcribe', help='Benchmark a local engine; never uploads input audio.')
    engine.add_argument('--engine', choices=['faster-whisper', 'qwen'], required=True)
    engine.add_argument('--model', required=True)
    engine.add_argument('--device', choices=['cpu', 'cuda'], default='cpu')
    engine.add_argument('--input', type=Path, required=True)
    engine.add_argument('--reference', type=Path)
    engine.add_argument('--language', choices=['zh', 'en', 'auto'], default='auto')
    engine.add_argument('--allow-download', action='store_true')
    engine.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(argv)
    if args.command == 'capture' and (not math.isfinite(args.seconds) or not 0 < args.seconds <= 120):
        parser.error('--seconds must be greater than zero and no more than 120')
    if args.output.exists():
        parser.error('The report already exists. Choose a new output path to preserve prior evidence.')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    report = inspect_devices() if args.command == 'devices' else capture(args) if args.command == 'capture' else transcribe(args)
    write_report(args.output, report)
    print(json.dumps(dict(status=report['status'], report=str(args.output)), ensure_ascii=False))
    return 0 if report['status'] in ['inspected', 'captured', 'transcribed'] else 2


if __name__ == '__main__':
    multiprocessing.freeze_support()
    raise SystemExit(main())
