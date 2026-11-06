import pathlib,sys
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'Native/QwenRuntime'))
from speaker_timeline import SpeakerTimeline
s=SpeakerTimeline(.08)
s.append([[.1,.1],[.1,.1]],0,.15,[[.1,.1],[.1,.1]])
s.append([[.8,.1],[.8,.1]],.15,.15,[[.8,.1],[.8,.1],[.8,.1],[.8,.1]])
t=s.turns(min_duration=.01)
assert t==[dict(start=0,end=.30,speaker='0')],t
assert s.times[-1][1]==.30, 'Frame rounding must not accumulate into actual audio offsets'
s.append([[.1,.9],[.1,.9]],.30,.15,[[.8,.1],[.8,.1],[.1,.9],[.1,.9]])
t=s.turns(min_duration=.01)
assert t[0]['speaker']=='0'and t[1]['speaker']=='1'and abs(t[1]['start']-.30)<1e-8
s=SpeakerTimeline(.08);s.append([[.9,.9],[.9,.9]],0,.16,[[.9,.9],[.9,.9]])
assert len(s.turns())==2, 'Overlapping speakers must remain independent'
assert s.frames()==[[0,.08,.9,.9],[.08,.16,.9,.9]],'Sentence attribution must receive unthresholded, globally identified model evidence'
try:s.append([[1.1,.2]],.16,.08,[]);raise AssertionError('Invalid probability accepted')
except ValueError:pass
s.append([], .16, .001, [])
print('PASS: retrospective model corrections, actual sample-time offsets, speaker changes, overlap and invalid probabilities')
