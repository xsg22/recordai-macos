"""Discard only the left-context prefix, retaining exact text evidence."""
from speaker_attribution import normalized

def splice_prefix(original,repaired,count,seconds):
    import math
    text=lambda ws:''.join(w.get('separator','')+w['text'] for w in ws)
    if not(0<count<len(original) and 0<seconds<=24):raise ValueError('Invalid seam repair range')
    if text(original[:count])!=text(repaired):raise ValueError('Seam repair changed recognized text')
    previous=-1
    for word in repaired:
        a,b=word['start'],word['end']
        if not(math.isfinite(a) and math.isfinite(b) and 0<=a<=b<=seconds+0.001 and a>=previous-0.15):raise ValueError('Invalid repaired alignment')
        previous=a
    if not repaired or repaired[-1]['end']>original[count]['start']+0.15:raise ValueError('Seam repair overlaps cached tail')
    return repaired+original[count:]

def crop(words,cut,previous_text,proof=None):
    if cut<=0:return list(words),[]
    dropped=[];kept=[];acknowledged_edges=set()
    for word in words:
        (dropped if word['end']<=cut+1e-8 else kept).append(word)
    context=normalized(previous_text)
    # A word can straddle the transport edge and already be present in the
    # accepted prefix. Require a strong exact whole-context suffix, not fuzzy
    # word similarity or a new repetition beginning after the boundary.
    while kept and kept[0]['start']<cut-1e-8:
        prefix=normalized(''.join(w['text']for w in dropped+[kept[0]]))
        if len(prefix)>=4 and context.endswith(prefix):
            edge=kept.pop(0);dropped.append(edge);acknowledged_edges.add(id(edge))
            if proof is not None:proof.append(dict(method='acknowledged-straddler',start=edge['start'],end=edge['end'],contextSuffixLength=len(prefix),cut=cut))
        else:break
    uncertain=[]
    for index,word in enumerate(words):
        if word not in dropped or word['end']>word['start']:continue
        # A zero duration is not a transport boundary. Ordered alignment can
        # still prove ownership when the following reliable anchor finishes
        # strictly inside the old context. Keep the original times unchanged.
        right=next((w for w in words[index+1:] if w['end']>w['start']),None)
        left=next((w for w in reversed(words[:index]) if w['end']>w['start']),None)
        acknowledged=right is not None and id(right)in acknowledged_edges
        bounded=(right is not None and right['start']>=word['start']-0.15
                 and (right['end']<=cut-0.05 or acknowledged)
                 and (left is None or left['end']<=cut-0.05))
        if bounded:
            if proof is not None:proof.append(dict(index=index,method='acknowledged-right-anchor'if acknowledged else'ordered-left-context',leftEnd=None if left is None else left['end'],rightEnd=right['end'],cut=cut))
        else:uncertain.append(word)
    if uncertain:
        # Text equality alone cannot distinguish a repeated word at the edge
        # from its occurrence in the previous batch. Keep both candidates and
        # ask the bounded seam aligner instead of silently deleting the word.
        raise ValueError('Overlap word timing uncertain; original audio and both candidates retained')
    return kept,dropped
