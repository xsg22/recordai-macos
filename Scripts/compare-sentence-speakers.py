#!/usr/bin/env python3
"""Compare attribution policies on identical recognized text, words and voice.

Legacy module is an explicitly retained baseline source, not another ASR run.
Optional truth contains real human utterance intervals with known speaker IDs.
Natural recordings without checked truth cannot establish speaker accuracy.
"""
import argparse,collections,importlib.util,itertools,json,sys,unicodedata
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Native/QwenRuntime'))
from paragraphs import group_words,length
from sentence_speakers import attribute_sentences

def compare(alignment,voice,legacy,truth=None):
    words=alignment['alignedWords'];text=''.join(w.get('separator','')+w['text'] for w in words)
    # Preserve the former per-alignment-clip grouping, including separators.
    clips=[]
    for w in words:
        if not clips or w.get('separator'):clips.append([])
        clips[-1].append(w)
    old=[]
    for clip in clips:
        rows=legacy.attribute(''.join(w['text'] for w in clip),clip,voice['turns'],0,voice['duration'])
        if rows:rows[0]['separator']=clip[0].get('separator','')
        old.extend(rows)
    old=group_words(old);new=alignment['paragraphs']
    assert text==''.join(r.get('separator','')+r['text'] for r in old)==''.join(r.get('separator','')+r['text'] for r in new),'Text changed by attribution'
    def metrics(rows):
        return dict(paragraphs=len(rows),tinyParagraphs=sum(0<length(r['text'])<=3 for r in rows),unknownCharacters=sum(length(r['text']) for r in rows if not r['speakerIDs']),pendingTimeRows=sum(r['end']<=r['start'] or r.get('timingUncertain',False) for r in rows),knownSpeakerIDs=sorted({s for r in rows for s in r['speakerIDs']}))
    result=dict(sameASRTextAndWordTimes=True,textCharacters=len(text),legacy=metrics(old),sentence=metrics(new))
    if truth:
        segments=truth['segments'];speakers=sorted({s['speaker'] for s in segments})
        def assess(rows):
            pairs=[]
            for s in segments:
                mid=(s['start']+s['end'])/2
                hits=[r['speakerIDs'][0] for r in rows if len(r['speakerIDs'])==1 and r['start']<=mid<=r['end']]
                pairs.append((s['speaker'],hits[0] if len(set(hits))==1 else None))
            slots=sorted({p[1] for p in pairs if p[1]is not None})
            candidates=[dict(zip(slots,perm)) for perm in itertools.permutations(speakers,len(slots))] if len(slots)<=len(speakers) else [{}]
            mapping=max(candidates,key=lambda m:sum(m.get(b)==a for a,b in pairs))
            correct=sum(mapping.get(b)==a for a,b in pairs);unknown=sum(b is None for _,b in pairs)
            changes=[(a,b) for a,b in zip(segments,segments[1:]) if a['speaker']!=b['speaker']]
            crossings=[dict(left=a['id'],right=b['id'],paragraph=i) for a,b in changes for i,r in enumerate(rows) if r['start']<a['end']-.35 and r['end']>b['start']+.35]
            gaps=[(a,b) for a,b in zip(segments,segments[1:]) if b['start']-a['end']>5 and a['speaker']==b['speaker']]
            crossedGaps=sum(any(r['start']<a['end'] and r['end']>b['start'] for r in rows) for a,b in gaps)
            return dict(utteranceMidpoints=len(pairs),correctKnown=correct,wrongKnown=len(pairs)-correct-unknown,unknownOrOverlap=unknown,speakerMapping=mapping,realSpeakerChanges=len(changes),paragraphsCrossingSpeakerChanges=len(crossings),crossings=crossings,longSameSpeakerGaps=len(gaps),paragraphsCrossingLongGaps=crossedGaps)
        result['controlledTruth']=dict(legacy=assess(old),sentence=assess(new),kind='Controlled concatenation of real human utterances; midpoint checks are not natural-conversation DER')
    return result,old

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['alignment','diarization','legacy-module','output']:p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--truth',type=Path);args=p.parse_args()
    spec=importlib.util.spec_from_file_location('legacy_attribution',args.legacy_module);legacy=importlib.util.module_from_spec(spec);spec.loader.exec_module(legacy)
    report,old=compare(json.loads(args.alignment.read_text()),json.loads(args.diarization.read_text()),legacy,json.loads(args.truth.read_text()) if args.truth else None)
    args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2))
    args.output.with_name(args.output.stem+'-legacy-paragraphs.json').write_text(json.dumps(old,ensure_ascii=False,indent=2))
    print(json.dumps(report,ensure_ascii=False))
if __name__=='__main__':main()
