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

from overlap_words import crop
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
print('PASS: aligned seam cropping, exact straddling-word reuse, true repetitions, zero-time prefix and uncertainty retention')
