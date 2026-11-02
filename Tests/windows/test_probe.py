import argparse
import contextlib
import importlib.util
import io
import json
import math
import queue
from pathlib import Path
import struct
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
import wave

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('recordai_probe', ROOT / 'Platforms/Windows/recordai_probe.py')
probe = importlib.util.module_from_spec(spec); spec.loader.exec_module(probe)


class ProbeTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='RecordAI validation 中文 ')
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)

    def wav(self, name='input.wav', silence=False):
        path = self.root / name
        with wave.open(str(path), 'wb') as stream:
            stream.setnchannels(1); stream.setsampwidth(2); stream.setframerate(16000)
            stream.writeframes(b''.join(struct.pack('<h', 0 if silence else int(8000 * math.sin(2 * math.pi * 440 * i / 16000))) for i in range(1600)))
        return path

    def test_silence_is_not_audio_signal(self):
        silent = probe.audio_stats(self.wav(silence=True))
        voiced = probe.audio_stats(self.wav('tone.wav'))
        self.assertFalse(silent['signalDetected']); self.assertTrue(voiced['signalDetected'])
        self.assertEqual(voiced['frames'], 1600); self.assertEqual(voiced['duration'], .1)

    def test_no_windows_is_not_hardware_success(self):
        with patch.object(probe.platform, 'system', return_value='Darwin'):
            report = probe.inspect_devices()
        self.assertEqual(report['status'], 'unsupported')
        self.assertFalse(report['hardwareCaptureValidated'])

    def test_no_devices_is_not_capture_success(self):
        args = argparse.Namespace(seconds=1, source='system')
        with patch.object(probe, 'inspect_devices', return_value=dict(status='unavailable', hardwareCaptureValidated=False)):
            report = probe.capture(args)
        self.assertEqual(report['status'], 'unavailable'); self.assertFalse(report['hardwareCaptureValidated'])

    def test_quality_is_measured_not_assumed(self):
        self.assertEqual(probe.quality("Don't change RecordAI!", "don't change recordai.")['wordErrorRate'], 0)
        self.assertEqual(probe.quality('离线转录', '离线记录')['characterErrorRate'], .25)
        self.assertIsNone(probe.quality('', '')['wordErrorRate'])

    def test_bad_timestamps_fail(self):
        for row in [dict(start=math.nan, end=1), dict(start=2, end=1), dict(start=-1, end=1), dict(start=0, end=12)]:
            with self.assertRaises(ValueError): probe.validate_segments([row], 2)
        with self.assertRaises(ValueError): probe.validate_segments([dict(start=1, end=1.5), dict(start=0, end=.5)], 2)

    def test_report_is_atomic_and_unicode_safe(self):
        path = self.root / '结果/report.json'
        probe.write_report(path, {'status': 'unsupported', 'title': '中文 / English'})
        self.assertEqual(json.loads(path.read_text(encoding='utf-8'))['title'], '中文 / English')
        self.assertFalse(list(path.parent.glob('*.partial')))

    def test_capture_time_is_bounded_before_accessing_hardware(self):
        for seconds in ['nan', '-1', '0', '121']:
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                probe.main(['capture', '--source', 'both', '--seconds', seconds, '--output', str(self.root / 'result.json')])

    def test_existing_evidence_is_not_overwritten(self):
        output = self.root / 'result.json'; output.write_text('preserve')
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            probe.main(['devices', '--output', str(output)])
        self.assertEqual(output.read_text(), 'preserve')

    def test_offline_default_rejects_remote_model_before_import(self):
        audio = self.wav()
        args = argparse.Namespace(engine='faster-whisper', device='cpu', model='remote-model', input=audio,
                                  language='en', allow_download=False, reference=None)
        report = probe.transcribe(args)
        self.assertEqual(report['status'], 'failed')
        self.assertIn('--allow-download', report['error'])

    def test_engine_contract_preserves_input_and_reports_truth(self):
        audio = self.wav(); before = audio.read_bytes()
        model = self.root / 'local model'; model.mkdir()
        (model / 'model.bin').write_bytes(b'fixture')
        calls = []
        class Model:
            def __init__(self, path, **options): calls.append(options)
            def transcribe(self, source, **options):
                calls.append(options)
                row = types.SimpleNamespace(start=0., end=.1, text='Hello, RecordAI.', words=[])
                return iter([row]), types.SimpleNamespace(language='en')
        args = argparse.Namespace(engine='faster-whisper', device='cpu', model=str(model), input=audio,
                                  language='en', allow_download=False, reference=None)
        with patch.dict(sys.modules, faster_whisper=types.SimpleNamespace(WhisperModel=Model)), patch.object(probe.platform, 'system', return_value='Darwin'):
            report = probe.transcribe(args)
        self.assertEqual(report['status'], 'transcribed')
        self.assertFalse(report['nativeWindowsInferenceValidated'])
        self.assertFalse(report['hardwareCaptureValidated'])
        self.assertTrue(calls[0]['local_files_only']); self.assertEqual(calls[0]['compute_type'], 'int8')
        self.assertEqual(calls[1]['task'], 'transcribe'); self.assertEqual(calls[1]['language'], 'en')
        self.assertEqual(audio.read_bytes(), before)
        args.reference = self.root / 'missing-reference.txt'
        with patch.dict(sys.modules, faster_whisper=types.SimpleNamespace(WhisperModel=Model)):
            failed = probe.transcribe(args)
        self.assertEqual(failed['status'], 'failed', 'Reference/reporting failures must not retain success status')
        self.assertIn('missing-reference', failed['error'])

    def test_invalid_word_timestamps_fail(self):
        with self.assertRaises(ValueError):
            probe.validate_segments([dict(start=0, end=1, words=[dict(start=0, end=math.inf)])], 1)

    def run_capture_worker(self, failure=None, silence=False, changed=False):
        device = dict(index=1, name='Test WASAPI', hostApi=2, maxInputChannels=1, defaultSampleRate=16000)
        class Stream:
            def start_stream(self): pass
            def stop_stream(self): pass
            def close(self): pass
            def is_active(self): return True
            def read(self, frames, exception_on_overflow):
                self.assert_overflow = exception_on_overflow
                if failure: raise OSError(failure)
                return struct.pack('<h', 0 if silence else 8000) * frames
        class Manager:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def get_device_info_by_index(self, index): return dict(device, name='Replaced') if changed else device
            def open(self, **kwargs): return Stream()
        event = types.SimpleNamespace(wait=lambda timeout: True)
        ready, results = queue.Queue(), queue.Queue()
        path = self.root / 'capture.wav'
        with patch.dict(sys.modules, pyaudiowpatch=types.SimpleNamespace(PyAudio=Manager, paInt16=8)):
            probe.capture_track(device, .1, path, event, ready, results)
        return results.get_nowait(), path

    def test_capture_worker_checks_real_frames_and_signal(self):
        report, path = self.run_capture_worker()
        self.assertEqual(report['status'], 'captured')
        self.assertEqual(report['audio']['frames'], 1600)
        self.assertTrue(path.exists()); self.assertFalse(path.with_name('capture.partial.wav').exists())

    def test_capture_worker_silence_is_not_passed(self):
        report, path = self.run_capture_worker(silence=True)
        self.assertEqual(report['status'], 'needs_signal'); self.assertTrue(path.exists())

    def test_capture_worker_device_replacement_fails(self):
        report, path = self.run_capture_worker(changed=True)
        self.assertEqual(report['status'], 'failed'); self.assertIn('device changed', report['error'])
        self.assertFalse(path.exists())

    def test_capture_worker_driver_overflow_preserves_partial(self):
        report, path = self.run_capture_worker(failure='Input overflowed')
        self.assertEqual(report['status'], 'failed'); self.assertIn('overflow', report['error'])
        self.assertFalse(path.exists()); self.assertTrue(path.with_name('capture.partial.wav').exists())


if __name__ == '__main__':
    unittest.main()
