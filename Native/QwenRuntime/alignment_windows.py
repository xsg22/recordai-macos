"""Partition long-window text for <=300s forced alignment without rewriting it.

A bounded guide recognition locates a text boundary. It never replaces the
long-window transcript. A low-confidence guide yields no invented timing.
"""
import unicodedata
import statistics
from inference_policy import RATE,MAX_ALIGNMENT_SECONDS,generate_complete

class AlignmentWindowError(ValueError):pass

def alignment_cut(audio):
    """Find a nearby quiet pause without discarding any audio or transcript."""
    context=round(.2*RATE);frame=round(.02*RATE);middle=len(audio)//2
    lower=max(context,len(audio)-MAX_ALIGNMENT_SECONDS*RATE+context,middle-45*RATE)
    upper=min(len(audio)-context,MAX_ALIGNMENT_SECONDS*RATE-context,middle+45*RATE)
    energies=[]
    for start in range(lower,upper-frame+1,frame):
        values=audio[start:start+frame]
        energies.append((start,sum(float(v)**2 for v in values)/frame))
    if not energies:raise AlignmentWindowError('No bounded alignment split is available')
    threshold=max((2/32768)**2,min(.005**2,statistics.median(v for _,v in energies)*.02))
    pauses=[];begin=None
    for index,(_,energy) in enumerate(energies+[(upper,float('inf'))]):
        if energy<=threshold:
            if begin is None:begin=index
        elif begin is not None:
            if index-begin>=5:
                lo=energies[begin][0];hi=energies[index-1][0]+frame
                pauses.append((lo+hi)//2)
            begin=None
    if not pauses:raise AlignmentWindowError('No confident quiet pause near the alignment boundary')
    return min(pauses,key=lambda p:abs(p-middle))

def units(text):
    result=[];i=0
    def han(c):return 0x3400<=ord(c)<=0x9fff or 0x20000<=ord(c)<=0x323af
    def letter(c):return unicodedata.category(c)[0] in 'LN'
    while i<len(text):
        if not letter(text[i]):i+=1;continue
        start=i;i+=1
        if not han(text[start]):
            while i<len(text) and not han(text[i]):
                if letter(text[i]):i+=1
                elif text[i] in "'’" and i+1<len(text) and letter(text[i+1]) and not han(text[i+1]):i+=1
                else:break
        result.append((text[start:i].casefold().replace('’',"'"),start,i))
    return result

def prefix_boundary(text,guide):
    target=units(text);source=units(guide)
    if not target or not source:raise AlignmentWindowError('Alignment guide has no reliable words')
    a=[x[0] for x in source];b=[x[0] for x in target]
    if len(a)*len(b)>12_000_000:raise AlignmentWindowError('Alignment guide comparison exceeds bounded work')
    prior=list(range(len(b)+1))
    for i,x in enumerate(a,1):
        row=[i]+[0]*len(b)
        for j,y in enumerate(b,1):row[j]=min(prior[j]+1,row[j-1]+1,prior[j-1]+(x!=y))
        prior=row
    best=min(range(1,len(b)+1),key=lambda j:(prior[j],abs(j-len(a)),j))
    confidence=1-prior[best]/max(len(a),best)
    if confidence<.80 or min(len(a),best)<4:raise AlignmentWindowError('Alignment guide cannot confidently locate the text boundary')
    return (target[best][1] if best<len(target) else len(text)),confidence

def prepare(model,audio,text,*,language,hotwords=None):
    duration=len(audio)/RATE
    if duration<=MAX_ALIGNMENT_SECONDS:return [dict(text=text,start=0.,end=duration)]
    context=.2
    lower=max(context,duration-MAX_ALIGNMENT_SECONDS+context)
    upper=min(duration-context,MAX_ALIGNMENT_SECONDS-context)
    if lower>=upper:raise AlignmentWindowError('Long ASR window needs more alignment partitions')
    candidates=[]
    try:candidates.append(alignment_cut(audio)/RATE)
    except AlignmentWindowError:pass
    # A long quiet tail can make a midpoint guide contain the entire text.
    # Try an earlier bounded guide rather than discarding the completed text
    # or assigning invented word timestamps to its whole ASR window.
    candidates.extend([max(lower,min(t,upper))for t in (30.,60.,90.,120.)])
    candidates.append(min(upper,max(lower,duration-30.)))
    seen=set();failures=[]
    for cut in candidates:
        cut=max(lower,min(upper,cut));middle=round(cut*RATE);cut=middle/RATE
        if middle in seen:continue
        seen.add(middle)
        try:
            guide=generate_complete(model,audio[:middle],language=language,hotwords=hotwords).text.strip()
            if not units(guide) and not any(abs(float(x))>2/32768 for x in audio[:middle]):
                return [dict(text=text,start=max(0.,cut-context),end=duration)]
            if [u[0] for u in units(text)] == [u[0] for u in units(guide)] and not any(abs(float(x))>2/32768 for x in audio[middle:]):
                return [dict(text=text,start=0.,end=min(duration,cut+context))]
            split,confidence=prefix_boundary(text,guide)
            if split==len(text):raise AlignmentWindowError('Guide covers all text before non-silent audio ends')
            parts=[dict(text=text[:split],start=0.,end=min(duration,cut+context),confidence=confidence),dict(text=text[split:],start=max(0.,cut-context),end=duration,confidence=confidence)]
            if ''.join(p['text']for p in parts)!=text or any(not p['text']or p['end']-p['start']>MAX_ALIGNMENT_SECONDS for p in parts):raise AlignmentWindowError('Alignment partitions do not preserve the full transcript')
            return parts
        except (AlignmentWindowError,ValueError)as error:failures.append(str(error))
    raise AlignmentWindowError('; '.join(failures)or 'No reliable bounded text boundary')
