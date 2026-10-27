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
