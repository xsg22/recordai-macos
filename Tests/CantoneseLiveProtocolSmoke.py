import contextlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
import mlx.core
import numpy

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Native/QwenRuntime'))
spec = importlib.util.spec_from_file_location('qwen_worker', ROOT / 'Native/QwenRuntime/worker.py')
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class LiveProtocolTests(unittest.TestCase):
    def run_worker(self, packets):
        calls = []
        class Model:
            def generate(self, **kwargs):
                calls.append(kwargs)
                return types.SimpleNamespace(text='我哋開會', generation_tokens=2)
        stt = types.ModuleType('mlx_audio.stt')
        stt.load = lambda _: Model()
        fake_stdin = types.SimpleNamespace(buffer=io.BytesIO(packets))
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as model, patch.dict(sys.modules, {'mlx_audio.stt': stt}), patch.object(sys, 'stdin', fake_stdin), contextlib.redirect_stdout(output):
            worker.live_cantonese(model)
        return calls, [json.loads(line) for line in output.getvalue().splitlines()]

    def test_packet_boundaries_final_tail_and_silence(self):
        def packet(value, count): return struct.pack('<I', count) + struct.pack('<f', value) * count
        calls, events = self.run_worker(packet(.1, 40000) + packet(.1, 40000) + packet(0, 16000))
        self.assertEqual([e['type'] for e in events], ['ready', 'commit', 'commit', 'done'])
        self.assertEqual([(e['start'], e['end']) for e in events[1:3]], [(0, 4), (4, 6)])
        self.assertTrue(all(call['language'] == 'Cantonese' for call in calls))
        self.assertEqual(len(calls), 2)

    def test_invalid_header_and_truncated_packet_rejected(self):
        for data in [b'\x01', struct.pack('<I', 0), struct.pack('<I', 64001), struct.pack('<I', 2) + b'\x00']:
            with self.subTest(data=data), self.assertRaises(ValueError): self.run_worker(data)


if __name__ == '__main__': unittest.main()
