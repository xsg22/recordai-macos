import pathlib,sys
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'Native/QwenRuntime'))
from speaker_attribution import attribute
text='你好，小王。 Hello, world!'
items=[dict(text='你',start=0,end=.2),dict(text='好',start=.2,end=.4),dict(text='小',start=.5,end=.7),dict(text='王',start=.7,end=.9),dict(text='Hello',start=1,end=1.4),dict(text='world',start=1.5,end=2)]
turns=[dict(start=10,end=11,speaker='0'),dict(start=11,end=12,speaker='1')]
rows=attribute(text,items,turns,10,2)
assert ''.join(r['text'] for r in rows)==text and len(rows)==2
assert rows[0]['speakerIDs']==['0'] and rows[1]['speakerIDs']==['1']
overlap=attribute('抢话',[dict(text='抢',start=0,end=.5),dict(text='话',start=.5,end=1)],[dict(start=0,end=1,speaker='0'),dict(start=0,end=1,speaker='1')],0,1)
assert overlap[0]['speakerIDs']==['0','1']
unknown=attribute('未知',[dict(text='未',start=0,end=.5),dict(text='知',start=.5,end=1)],[],0,1)
assert unknown[0]['speakerIDs']==[]
try:attribute('不可丢字',items,[],0,2);raise AssertionError('必须拒绝不完整对齐')
except ValueError:pass
print('PASS: 中文英文标点空格完整保留、两人切换、重叠与未知、对齐不完整拒绝。')

# Rapid attribution jitter inside a sentence must not create single-character rows.
from speaker_attribution import coalesce_fragments
jitter = [dict(text=t, start=i*.18, end=(i+1)*.18, speakerIDs=([str(i%2)] if i%3 else []), separator='') for i,t in enumerate('页面点击不能让他选中复制。')]
compact = coalesce_fragments(jitter)
assert ''.join(r['text'] for r in compact) == ''.join(r['text'] for r in jitter)
assert sum(len(r['text']) == 1 for r in compact) < sum(len(r['text']) == 1 for r in jitter)
assert all(not r['speakerIDs'] for r in compact), 'Do not invent a stable or overlapping speaker from jitter'
answers = [dict(text='嗯。',start=0,end=.2,speakerIDs=['0'],separator=''),dict(text='好。',start=.2,end=.4,speakerIDs=['1'],separator='')]
assert coalesce_fragments(answers) == answers
paused = [dict(text='页',start=0,end=.2,speakerIDs=[],separator=''),dict(text='面',start=2,end=2.2,speakerIDs=[],separator='')]
assert coalesce_fragments(paused) == paused
assert coalesce_fragments(compact) == compact, 'Compaction should be idempotent'
print('PASS: 连续短碎段合并、正文与时间边界保全、未知归属不冒充重叠、完整短答及静音分界保留。')

english = [dict(text='OK.',start=0,end=.2,speakerIDs=['0'],separator=''),dict(text='Yes.',start=.2,end=.4,speakerIDs=['1'],separator='')]
assert coalesce_fragments(english) == english
print('PASS: 英文句末短答边界保留。')
