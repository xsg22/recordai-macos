"""Sentence-level voice attribution; punctuation never overrides clear turn-taking.

Probabilities come from one continuous diarization session, not a new model per
sentence. Weak frame/word fluctuations cannot independently label a character.
All boundaries remain on aligned tokens; no text or timing is synthesized.
"""
import bisect,math
from paragraphs import ends_sentence,group_words
from sentence_rules import sentence_ends

class VoiceEvidence:
    def __init__(self,turns,frames=None):
        if frames is None:
            # Also accept historical/test hard turns. Product emits soft frames.
            points=sorted({t[k] for t in turns for k in ('start','end')})
            speakers=sorted({str(t['speaker']) for t in turns})
            self.frames=[(a,b,{s:float(any(str(t['speaker'])==s and t['start']<=a and t['end']>=b for t in turns)) for s in speakers}) for a,b in zip(points,points[1:]) if b>a]
        else:
            self.frames=[];previous=0
            for frame in frames:
                if not 3<=len(frame)<=6 or any(not math.isfinite(x) for x in frame):raise ValueError('Invalid voice evidence')
                a,b,*scores=frame
                if not 0<=a<b or a<previous-1e-8 or any(not 0<=p<=1 for p in scores):raise ValueError('Invalid voice frame timing or probabilities')
                previous=b
                self.frames.append((a,b,{str(i):p for i,p in enumerate(scores)}))
        self.ends=[f[1] for f in self.frames]

    def pieces(self,words):
        # Union word supports: ignore silence between words and avoid counting
        # overlapping aligner intervals twice. Zero-length items supply no voice.
        supports=[]
        for w in words:
            a,b=w['start'],w['end']
            if b<=a:continue
            if supports and a<=supports[-1][1]:supports[-1][1]=max(b,supports[-1][1])
            else:supports.append([a,b])
        result=[]
        for a,b in supports:
            i=bisect.bisect_right(self.ends,a)
            while i<len(self.frames) and self.frames[i][0]<b:
                lo,hi,scores=self.frames[i];lo=max(lo,a);hi=min(hi,b)
                if hi>lo and max(scores.values(),default=0)>=.45:result.append((lo,hi,scores))
                i+=1
        return result

def decisive_runs(pieces):
    runs=[]
    for a,b,scores in pieces:
        ranked=sorted(scores,key=scores.get,reverse=True)
        active=tuple(sorted(s for s in ranked if scores[s]>=.72))
        who=active if len(active)>1 else (ranked[0],)
        p=min(scores[s] for s in who)
        margin=p-max((v for s,v in scores.items() if s not in who),default=0)
        if p<.72 or margin<.25:continue
        if runs and runs[-1]['who']==who and a-runs[-1]['end']<=.24+1e-8:
            r=runs[-1];r['end']=b;r['support']+=b-a;r['mass']+=(b-a)*p;r['margin']+=(b-a)*margin
        else:runs.append(dict(who=who,start=a,end=b,support=b-a,mass=(b-a)*p,margin=(b-a)*margin))
    # Short high-confidence interjections remain protected. Punctuation-delimited
    # short replies are independent sentences and do not need this duration gate.
    return [r for r in runs if r['support']>=.40-1e-8 or (r['support']>=.16-1e-8 and r['mass']/r['support']>=.9 and r['margin']/r['support']>=.6)]

def sentence_speaker(pieces):
    mass={};duration=0;overlap={}
    for a,b,scores in pieces:
        length=b-a;duration+=length
        for who,p in scores.items():mass[who]=mass.get(who,0)+length*p
        active=tuple(sorted(s for s,p in scores.items() if p>=.65))
        if len(active)>1:overlap[active]=overlap.get(active,0)+length
    if not duration:return []
    ranked=sorted(mass,key=mass.get,reverse=True);best=ranked[0]
    if overlap:
        pair=max(overlap,key=overlap.get)
        if overlap[pair]>=duration*.5 and all(mass[s]>=duration*.55 for s in pair):return list(pair)
    second=mass[ranked[1]] if len(ranked)>1 else 0
    return [best] if mass[best]>=duration*.52 and mass[best]-second>=duration*.16 else []

def attribute_sentences(words,turns,*,frames=None,protected_words=()):
    evidence=VoiceEvidence(turns,frames);sentences=[]
    full=''.join(w.get('separator','')+w['text']for w in words);boundaries=sentence_ends(full);cursor=0
    for word in words:
        if sentences:
            prev=sentences[-1][-1]
            if cursor not in boundaries and word['start']-prev['end']<=5+1e-8:
                sentences[-1].append(dict(word));cursor+=len(word.get('separator','')+word['text']);continue
        sentences.append([dict(word)])
        cursor+=len(word.get('separator','')+word['text'])
    output=[]
    for sentence in sentences:
        pieces=evidence.pieces(sentence);runs=decisive_runs(pieces);cuts=set()
        # A real voice change may precede ASR punctuation. Locate its closest
        # aligned-token boundary rather than assigning the whole sentence by vote.
        for left,right in zip(runs,runs[1:]):
            if left['who']==right['who']:continue
            when=(left['end']+right['start'])/2
            candidates=[i for i in range(1,len(sentence)) if sentence[i-1]['start']<right['end'] and sentence[i]['end']>left['start']]
            if candidates:cuts.add(min(candidates,key=lambda i:abs((sentence[i-1]['end']+sentence[i]['start'])/2-when)))
        indices=[0,*sorted(cuts),len(sentence)]
        for start,end in zip(indices,indices[1:]):
            unit=sentence[start:end];speakers=sentence_speaker(evidence.pieces(unit))
            output.extend(dict(w,speakerIDs=speakers) for w in unit)
    return group_words(output,protected_words=protected_words)
