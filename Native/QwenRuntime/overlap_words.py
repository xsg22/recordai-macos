"""Discard only the left-context prefix, retaining exact text evidence."""
from speaker_attribution import normalized

def crop(words,cut,previous_text):
    if cut<=0:return list(words),[]
    dropped=[];kept=[]
    for word in words:
        (dropped if word['end']<=cut+1e-8 else kept).append(word)
    context=normalized(previous_text)
    # A word can straddle the transport edge and already be present in the
    # accepted prefix. Require a strong exact whole-context suffix, not fuzzy
    # word similarity or a new repetition beginning after the boundary.
    while kept and kept[0]['start']<cut-1e-8:
        prefix=normalized(''.join(w['text']for w in dropped+[kept[0]]))
        if len(prefix)>=4 and context.endswith(prefix):dropped.append(kept.pop(0))
        else:break
    if any(w['end']<=w['start']for w in dropped):
        fragment=normalized(''.join(w['text']for w in dropped))
        if fragment and not context.endswith(fragment):raise ValueError('Overlap word timing uncertain; original audio and both candidates retained')
    return kept,dropped
