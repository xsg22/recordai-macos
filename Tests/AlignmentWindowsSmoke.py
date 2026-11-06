import pathlib,sys,types,unittest
from unittest.mock import patch
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'Native/QwenRuntime'))
from alignment_windows import prefix_boundary,prepare,alignment_cut,AlignmentWindowError,RATE

class AlignmentWindowsTests(unittest.TestCase):
 def test_prefix_guide_does_not_rewrite_english(self):
  text="Alice reviewed the design. Bob will implement it, tomorrow."
  split,confidence=prefix_boundary(text,"Alice reviewed the design")
  self.assertEqual(text[:split],"Alice reviewed the design. ");self.assertGreater(confidence,.99)
  self.assertEqual(text[:split]+text[split:],text)
 def test_noisy_chinese_guide_still_preserves_exact_punctuation(self):
  text="今天讨论录音引擎，然后处理时间戳。下一步验证同步。"
  split,confidence=prefix_boundary(text,"今天讨论录音引擎然后处理时间错")
  self.assertEqual(text[:split],"今天讨论录音引擎，然后处理时间戳。");self.assertGreater(confidence,.8)
 def test_unrelated_guide_is_rejected(self):
  with self.assertRaises(AlignmentWindowError):prefix_boundary("This is a protected transcript.","Completely unrelated words here")
 def test_long_partition_exact_text_bounded_audio(self):
  # A compact zero-storage fake audio sequence exposes lengths/slices.
  class Audio:
   def __init__(self,n):self.n=n
   def __len__(self):return self.n
   def __getitem__(self,s):return Audio(len(range(*s.indices(self.n))))
  text="Alice reviewed the design. Bob will implement it, tomorrow."
  with patch('alignment_windows.alignment_cut',return_value=240*16000),patch('alignment_windows.generate_complete',return_value=types.SimpleNamespace(text="Alice reviewed the design")):
   rows=prepare(None,Audio(480*16000),text,language='English')
  self.assertEqual(''.join(x['text'] for x in rows),text)
  self.assertEqual([(x['start'],x['end']) for x in rows],[(0,240.2),(239.8,480)])
  self.assertTrue(all(x['end']-x['start']<=300 for x in rows))
 def test_short_window_needs_no_guide(self):
  with patch('alignment_windows.generate_complete',side_effect=AssertionError('must not run')):
   self.assertEqual(prepare(None,bytearray(30*16000),'keep',language='English'),[dict(text='keep',start=0.,end=30.)])
 def test_guide_failure_cannot_erase_completed_long_window_text(self):
  import worker
  class Audio:
   def __len__(self):return 480*16000
  text='Authoritative full-window transcript, including its ending.'
  with patch('worker.generate_complete',return_value=types.SimpleNamespace(text=text)),patch('alignment_windows.prepare',side_effect=AlignmentWindowError('Guide mismatch')):
   result=worker.recognized_segment(None,Audio(),start=0,end=480,language='English')
  self.assertEqual(result['text'],text);self.assertNotIn('alignmentParts',result)
  self.assertIn('alignmentIssue',result)
 def test_boundary_prefers_a_quiet_pause(self):
  from array import array
  audio=array('f',[.08])*(12*RATE)
  audio[round(5.8*RATE):round(6.2*RATE)]=array('f',[0])*round(.4*RATE)
  self.assertLess(abs(alignment_cut(audio)/RATE-6),.03)
 def test_no_pause_does_not_invent_a_boundary(self):
  from array import array
  with self.assertRaises(AlignmentWindowError):alignment_cut(array('f',[.08])*(12*RATE))
if __name__=='__main__':unittest.main()
