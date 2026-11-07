import pathlib,sys
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'Native/QwenRuntime'))
from speaker_attribution import attribute,aligned_words
from sentence_speakers import attribute_sentences,VoiceEvidence

def words(text,step=.2):
    return [dict(text=c,start=i*step,end=(i+1)*step) for i,c in enumerate(text) if c not in '。？！']
def frame(a,b,p,q):return [a,b,p,q]
def body(rows):return ''.join(r.get('separator','')+r['text'] for r in rows)

text='完整一句话不应被切成很多小块。'
items=words(text)
frames=[frame(i*.2,(i+1)*.2,.95,.03) for i in range(len(items))]
frames[3]=frame(.6,.8,.38,.35) # unknown
frames[7]=frame(1.4,1.6,.55,.7) # weak alternate label
r=attribute(text,items,[],0,len(items)*.2,frames=frames)
assert len(r)==1 and r[0]['speakerIDs']==['0'] and body(r)==text,r

# A punctuation-free real handoff must survive sentence pooling.
text='我先说你接着说'
items=words(text)
frames=[frame(i*.2,(i+1)*.2,*((.97,.01) if i<3 else (.01,.97))) for i in range(len(items))]
r=attribute(text,items,[],0,len(items)*.2,frames=frames)
assert [x['text'] for x in r]==['我先说','你接着说'] and [x['speakerIDs'] for x in r]==[['0'],['1']],r

# A short, confident interruption, followed by the original speaker.
text='我来说不继续说'
items=words(text)
frames=[frame(i*.2,(i+1)*.2,*((.01,.98) if i==3 else (.98,.01))) for i in range(len(items))]
r=attribute(text,items,[],0,len(items)*.2,frames=frames)
assert [x['text'] for x in r]==['我来说','不','继续说'],r

# Confident overlap inside an otherwise single-speaker sentence is explicit.
frames[3]=frame(.6,.8,.98,.98)
r=attribute(text,items,[],0,len(items)*.2,frames=frames)
assert [x['speakerIDs'] for x in r]==[['0'],['0','1'],['0']],r

# Punctuated short replies remain separate even below the sustained-turn gate.
r=attribute('嗯。好。',[dict(text='嗯',start=0,end=.12),dict(text='好',start=.12,end=.24)],[],0,.24,
            frames=[frame(0,.12,.95,.01),frame(.12,.24,.01,.95)])
assert [x['speakerIDs'] for x in r]==[['0'],['1']],r

text='待确认整句。'
r=attribute(text,words(text),[],0,1,frames=[frame(0,1,.5,.49)])
assert len(r)==1 and r[0]['speakerIDs']==[],r
r=attribute(text,words(text),[],0,1,frames=[frame(0,1,.9,.9)])
assert len(r)==1 and r[0]['speakerIDs']==['0','1'],r

# A sentence can cross ASR/alignment partitions; preserve the exact separator.
a=aligned_words('第一半句',[dict(text=c,start=i*.2,end=(i+1)*.2) for i,c in enumerate('第一半句')],0,1)
b=aligned_words('接着说完。',[dict(text=c,start=i*.2,end=(i+1)*.2) for i,c in enumerate('接着说完')],1,1)
b[0]['separator']='\n'
r=attribute_sentences(a+b,[],frames=[frame(0,2,.9,.01)])
assert len(r)==1 and body(r)=='第一半句\n接着说完。',r
late=[dict(x,start=x['start']+6.001,end=x['end']+6.001) for x in b]
r=attribute_sentences(a+late,[],frames=[frame(0,9,.9,.01)])
assert len(r)==2,'Pause over five seconds must split'

# Zero-duration output provides no fabricated voice evidence; surrounding real
# word times can still bound the complete sentence.
r=attribute('我说完。',[dict(text='我',start=0,end=0),dict(text='说',start=0,end=.2),dict(text='完',start=.2,end=.4)],[],0,.4,frames=[frame(0,.4,.95,.01)])
assert len(r)==1 and r[0]['start']==0 and r[0]['end']==.4 and body(r)=='我说完。',r
assert not r[0].get('timingUncertain') and r[0].get('hasUnalignedWords'),'A coincident real word anchor can bound the paragraph, without inventing the missing word time'
r=attribute('我说完。',[dict(text='我',start=0,end=0),dict(text='说',start=.3,end=.5),dict(text='完',start=.5,end=.7)],[],0,.7,frames=[frame(0,.7,.95,.01)])
assert len(r)==1 and r[0]['text']=='我说完。' and r[0].get('timingUncertain') is True,'An unresolved edge must never split the sentence'
assert r[0]['speakerIDs']==['0'] and r[0]['alignedStart']==.3 and r[0]['alignedEnd']==.7,'Keep true aligned playback bounds separate from uncertain full-sentence times'
from paragraphs import group_words
assert group_words(r)==r,'Regrouping must retain both full sentence and partial playback bounds'
r=attribute('说完了。',[dict(text='说',start=0,end=.2),dict(text='完',start=.2,end=.4),dict(text='了',start=.4,end=.4)],[],0,.4,frames=[frame(0,.4,.95,.01)])
assert not r[0].get('timingUncertain') and r[0]['end']==.4,'Coincident real end anchor must remain playable'
from paragraphs import group_words
assert group_words(r)==r,'Timing uncertainty and anchors must survive regrouping'
for frames in ([[0,1,1.1]], [[0,1,.8],[.5,2,.8]], [[0,float('nan'),.8]]):
    try:VoiceEvidence([],frames);raise AssertionError('Invalid voice evidence accepted')
    except ValueError:pass
print('PASS: sentence pooling, weak jitter, real mid-sentence handoff, short interruption/reply, overlap/unknown, cross-window sentence, pause, exact text and real time bounds')
