import importlib.util
import io
from pathlib import Path
import struct
import unittest
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('live_policy', ROOT/'Native/QwenRuntime/live_transcription.py')
live = importlib.util.module_from_spec(spec); spec.loader.exec_module(live)

class OnlineCantoneseTests(unittest.TestCase):
    def state(self):
        events = []; calls = []
        def decode(audio): calls.append(len(audio)); return '我哋今日開會。'
        return live.OnlinePhrases(decode, lambda *x: events.append(x), np), events, calls
    def pcm(self, seconds, level=.1):
        return np.full(int(seconds*16000), level, dtype='<f4').tobytes()
    def test_subtitles_arrive_while_input_remains_open(self):
        state, events, calls = self.state()
        for _ in range(8): state.push(self.pcm(.25))
        self.assertTrue(any(x[0]=='partial' for x in events))
        self.assertFalse(any(x[0]=='commit' for x in events))
        state.flush(); self.assertEqual(events[-1][0], 'commit')
    def test_silence_does_not_hallucinate(self):
        state, events, calls = self.state()
        for _ in range(60): state.push(self.pcm(.25, .00001))
        state.flush(); self.assertEqual(events, []); self.assertEqual(calls, [])
    def test_pause_flush_and_resume_keep_audio_timestamps(self):
        state, events, _ = self.state()
        state.push(self.pcm(2)); state.flush(); state.flush()
        state.push(self.pcm(2)); state.flush()
        commits = [e for e in events if e[0]=='commit']
        self.assertEqual(len(commits), 2); self.assertEqual(commits[1][2], 2)
        self.assertEqual(commits[-1][3], 4)
    def test_continuous_speech_is_bounded_and_keeps_tail(self):
        state, events, calls = self.state()
        for _ in range(60): state.push(self.pcm(.25))
        state.flush(); commits = [e for e in events if e[0]=='commit']
        self.assertGreaterEqual(len(commits), 2); self.assertLessEqual(max(calls), 12*16000)
        self.assertEqual(commits[-1][3], 15)
    def test_end_of_speech_commits_before_end_of_input(self):
        state, events, _ = self.state()
        state.push(self.pcm(1)); state.push(self.pcm(.7, 0))
        self.assertTrue(any(x[0]=='commit' for x in events))
    def test_partial_revisions_do_not_duplicate_final_phrases(self):
        state, events, _ = self.state()
        for _ in range(20): state.push(self.pcm(.25))
        state.flush(); self.assertEqual(len([x for x in events if x[0]=='commit']), 1)
    def test_frames_preserve_bytes_and_reject_truncation(self):
        pcm = self.pcm(.1); framed = struct.pack('<I', len(pcm)//4)+pcm
        self.assertEqual(list(live.pcm_frames(io.BytesIO(framed))), [pcm])
        with self.assertRaises(ValueError): list(live.pcm_frames(io.BytesIO(framed[:-2])))
        with self.assertRaises(ValueError): list(live.pcm_frames(io.BytesIO(struct.pack('<I',live.MAX_FRAME+1))))
    def test_non_finite_audio_is_rejected(self):
        state, _, _ = self.state()
        with self.assertRaises(ValueError): state.push(struct.pack('<f', float('nan')))

if __name__=='__main__': unittest.main()
