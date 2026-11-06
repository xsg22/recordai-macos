"""Align exact text, then attribute sentences using global voice evidence."""
import unicodedata,math

def normalized(text):
    return ''.join(c.casefold() for c in text if unicodedata.category(c)[0] in 'LN' or c=="'")

def aligned_words(text,items,offset,duration):
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
        part=text[charstart:charend]
        result.append(dict(text=part,start=start,end=end,separator=''))
        if end<=start:result[-1]['timingUncertain']=True
    if not words and text:result=[dict(text=text,start=offset,end=offset+duration,speakerIDs=[],separator='')]
    if ''.join(p['text'] for p in result)!=text:raise ValueError('分段未完整覆盖原文')
    return result

def attribute(text,items,turns,offset,duration,protected_words=(),frames=None):
    from sentence_speakers import attribute_sentences
    return attribute_sentences(aligned_words(text,items,offset,duration),turns,frames=frames,protected_words=protected_words)


def coalesce_fragments(rows):
    # Speaker changes are hard boundaries, including very short replies.
    from paragraphs import group_words
    return group_words(rows)
