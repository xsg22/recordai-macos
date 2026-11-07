import pathlib,sys
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'Native/QwenRuntime'))
from sentence_rules import sentence_ends
from speaker_attribution import attribute

def split(text):
    edges=[0,*sorted(sentence_ends(text))]
    if edges[-1]!=len(text):edges.append(len(text))
    return [text[a:b]for a,b in zip(edges,edges[1:])if b>a]

cases=[('你好。再见！',['你好。','再见！']),('Dr. Smith paid 3.14 at example.com. Then he left!',['Dr. Smith paid 3.14 at example.com. ','Then he left!']),('Use v0.17.3, e.g. this build. Done?',['Use v0.17.3, e.g. this build. ','Done?']),('「こんにちは。」次です！',['「こんにちは。」','次です！']),('أهلاً؟ نعم!',['أهلاً؟ ','نعم!']),('पहला वाक्य। दूसरा वाक्य॥',['पहला वाक्य। ','दूसरा वाक्य॥']),('«Très bien !» Ensuite.',['«Très bien !» ','Ensuite.'])]
for text,expected in cases:
    assert split(text)==expected,(text,split(text),expected)
    assert ''.join(split(text))==text
text='Dr. Smith paid 3.14. He left!'
items=[dict(text=w,start=i*.3,end=(i+1)*.3)for i,w in enumerate(['Dr','Smith','paid','3','14','He','left'])]
rows=attribute(text,items,[dict(start=0,end=3,speaker='0')],0,3)
assert ''.join(x['text']for x in rows)==text and len(rows)==1
print('PASS: Unicode sentence punctuation, closing quotes, abbreviations, decimals, hosts, versions, Latin/CJK/Arabic/Indic exact text')

from overlap_words import crop,splice_prefix
def w(text,start,end):return dict(text=text,start=start,end=end,separator='')
words=[w('alpha ',0,1),w('beta ',2.9,3.2),w('gamma.',3.2,4)]
kept,dropped=crop(words,3,'alpha beta')
assert ''.join(x['text']for x in kept)=='gamma.'
kept,dropped=crop(words,3,'alpha')
assert ''.join(x['text']for x in kept)=='beta gamma.'
kept,dropped=crop([w('alpha ',0,1),w('alpha.',3.01,4)],3,'alpha')
assert len(kept)==1 and kept[0]['text']=='alpha.' # a real repetition is new speech
kept,dropped=crop([w('我',0,0),w('说完。',.2,1)],0,'')
assert len(kept)==2 and not dropped
try:crop([w('未知',0,0),w('尾句。',3,4)],3,'别的内容');raise AssertionError('Uncertain overlap silently discarded')
except ValueError:pass
try:crop([w('结束。',1,2.8),w('我',3,3),w('继续。',3.2,4)],3,'结束。我');raise AssertionError('Text equality hid a possible new repetition')
except ValueError:pass
proof=[]
source=[w('麻',.48,.48),w('烦',.48,.56),w('点击三连。',.64,1.12),w('我们下期再见。',1.44,2.32),w('Deepseek',8.72,8.96)]
kept,dropped=crop(source,3,'麻烦点三连。我们下期再见。',proof)
assert ''.join(x['text']for x in kept)=='Deepseek' and len(proof)==1
assert source[0]['start']==source[0]['end']==.48 # ownership does not fabricate timing
proof=[]
words=[w('可以',2.72,2.88),w('在',2.88,2.88),w('这',2.88,3.04),w('里',3.04,3.2)]
kept,dropped=crop(words,3,'前文可以在这',proof)
assert ''.join(x['text']for x in kept)=='里' and any(x['method']=='acknowledged-right-anchor'for x in proof)
# The same edge without an acknowledged full prefix must remain uncertain.
try:crop(words,3,'另一段内容');raise AssertionError('Unconfirmed straddler used as an ownership anchor')
except ValueError:pass
try:crop([w('尾句。',1,2.8),w('我',3,3),w('继续。',3.2,4)],3,'尾句。');raise AssertionError('Ambiguous boundary word discarded')
except ValueError:pass
old=[w('我',0,0),w('说',1,2),w('完。',4,5)]
fixed=splice_prefix(old,[w('我',.2,.5),w('说',1,2)],2,2)
assert fixed[2] is old[2] and ''.join(x['text']for x in fixed)=='我说完。'
try:splice_prefix(old,[w('你',.2,.5),w('说',1,2)],2,2);raise AssertionError('Repair replaced ASR text')
except ValueError:pass
print('PASS: aligned seam cropping, exact straddling-word reuse, true repetitions, zero-time prefix and uncertainty retention')
