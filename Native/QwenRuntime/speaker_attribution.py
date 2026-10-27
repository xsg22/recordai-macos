"""将逐词时间与声音活动合并；正文字符必须完整保留，重叠和未知不强行归人。"""
import unicodedata,math

def normalized(text):
    return ''.join(c.casefold() for c in text if unicodedata.category(c)[0] in 'LN' or c=="'")

def attribute(text,items,turns,offset,duration):
    positions=[];clean=''
    for i,c in enumerate(text):
        if unicodedata.category(c)[0] in 'LN' or c=="'":
            folded=c.casefold();clean+=folded;positions.extend([i]*len(folded))
    words=[item for item in items if normalized(item['text'])]
    if ''.join(normalized(w['text']) for w in words)!=clean:raise ValueError('对齐词与原文不一致，正文保留且不强行添加发言人')
    cursor=0;result=[];previous=-1
    for index,w in enumerate(words):
        start,end=float(w['start']),float(w['end'])
        if not(math.isfinite(start) and math.isfinite(end) and 0<=start<=end<=duration+0.3 and start>=previous-0.15):raise ValueError('文字对齐时间异常')
        previous=start;start=min(duration,start)+offset;end=min(duration,end)+offset
        tokenlen=len(normalized(w['text']));charstart=0 if index==0 else positions[cursor]
        cursor+=tokenlen;charend=positions[cursor] if cursor<len(positions) else len(text)
        lo,hi=(start,end) if end-start>0.04 else (start-0.04,start+0.04)
        scores={}
        for turn in turns:
            overlap=max(0,min(hi,turn['end'])-max(lo,turn['start']))
            if overlap:scores[str(turn['speaker'])]=scores.get(str(turn['speaker']),0)+overlap
        ranked=sorted(scores,key=scores.get,reverse=True);span=hi-lo
        speakers=[s for s in ranked if scores[s]>=span*0.5][:4]
        if not speakers or (len(ranked)>1 and not (scores[ranked[0]]-scores[ranked[1]]>=span*.15) and len(speakers)==1):speakers=[]
        speakers=sorted(speakers)
        part=text[charstart:charend]
        if result and result[-1]['speakerIDs']==speakers and start-result[-1]['end']<=1.2 and len(result[-1]['text'])+len(part)<=180:
            result[-1]['text']+=part;result[-1]['end']=max(result[-1]['end'],end)
        else:result.append(dict(text=part,start=start,end=end,speakerIDs=speakers,separator=''))
    if not words and text:result=[dict(text=text,start=offset,end=offset+duration,speakerIDs=[],separator='')]
    if ''.join(p['text'] for p in result)!=text:raise ValueError('分段未完整覆盖原文')
    return result
