"""Reading paragraphs preserve every character and reliable speaker boundaries."""
import unicodedata,re

TARGET=50
SOFT_MAX=75
ENDINGS='。！？!?；;'
CLOSERS='”’"\'」』）)]} \t\r\n'

def ends_sentence(text):
    stripped=text.rstrip(CLOSERS)
    # A period following an English abbreviation/decimal is only a candidate
    # after the aligner's complete token; never split an individual token.
    return bool(stripped) and stripped[-1] in ENDINGS+'.'

def length(text):
    return sum(unicodedata.category(c)[0] in 'LN' for c in text)

def group_words(rows,protected_words=()):
    runs=[]
    for item in rows:
        row=dict(item);ids=row.get('speakerIDs',[])
        if runs:
            prev=runs[-1][-1]
            same=prev.get('speakerIDs',[])==ids
            gap=row['start']-prev['end']
            if same and -0.15<=gap<=5.0+1e-8 and (len(ids)==1 or ('\n' not in row.get('separator','') and not ends_sentence(prev['text']))):
                runs[-1].append(row);continue
        runs.append([row])
    result=[]
    for run in runs:
        full=''.join(x.get('separator','')+x['text']for x in run)
        spans=[m.span()for word in protected_words if word for m in re.finditer(re.escape(word),full,re.IGNORECASE)]
        offsets=[0]
        for x in run:offsets.append(offsets[-1]+len(x.get('separator','')+x['text']))
        pos=0
        while pos<len(run):
            counts=[];n=0
            for row in run[pos:]:n+=length(row.get('separator','')+row['text']);counts.append(n)
            if counts[-1]<=TARGET:stop=len(run)
            else:
                sentences=[i for i in range(pos,len(run)) if ends_sentence(run[i]['text']) and counts[i-pos]>=TARGET]
                if sentences and counts[sentences[0]-pos]<=SOFT_MAX:stop=sentences[0]+1
                else:
                    boundaries=[i for i in range(pos,len(run)) if run[i]['text'].rstrip(CLOSERS).endswith(tuple('，,、：:')) and TARGET//2<=counts[i-pos]<=SOFT_MAX]
                    if boundaries:stop=min(boundaries,key=lambda i:abs(counts[i-pos]-TARGET))+1
                    else:stop=next((i+1 for i in range(pos,len(run)) if counts[i-pos]>=TARGET),len(run))
            while stop<len(run)and any(lo<offsets[stop]<hi for lo,hi in spans):stop+=1
            block=dict(run[pos])
            for row in run[pos+1:stop]:
                block['text']+=row.get('separator','')+row['text'];block['end']=max(block['end'],row['end'])
            unit=run[pos:stop]
            if any(x.get('timingUncertain') or x.get('hasUnalignedWords') for x in unit):
                # Missing internal word times do not erase valid paragraph
                # boundaries. A zero-length boundary can use a coincident real
                # word anchor, never an interpolated/character-count estimate.
                start_bad=unit[0].get('startUncertain',unit[0].get('timingUncertain',False))
                end_bad=unit[-1].get('endUncertain',unit[-1].get('timingUncertain',False))
                starts=[x.get('alignedStart',x['start']) for x in unit if x.get('alignedStart') is not None or (not x.get('startUncertain',x.get('timingUncertain',False)) and x['end']>x['start'])]
                ends=[x.get('alignedEnd',x['end']) for x in unit if x.get('alignedEnd') is not None or (not x.get('endUncertain',x.get('timingUncertain',False)) and x['end']>x['start'])]
                if starts and abs(unit[0]['start']-starts[0])<=.15:start_bad=False
                if ends and abs(unit[-1]['end']-ends[-1])<=.15:end_bad=False
                for key in ['timingUncertain','startUncertain','endUncertain']:block.pop(key,None)
                block['hasUnalignedWords']=True
                # Explicit false values distinguish a grouped row with an
                # unresolved start from one with an unresolved end on regroup.
                block['startUncertain']=bool(start_bad);block['endUncertain']=bool(end_bad)
                for key in ['alignedStart','alignedEnd']:block.pop(key,None)
                if start_bad or end_bad:
                    block['timingUncertain']=True
                    if starts and ends and ends[-1]>starts[0]:
                        # Known acoustic bounds support partial playback, not a
                        # fabricated timestamp for the unresolved sentence edge.
                        block['alignedStart']=starts[0];block['alignedEnd']=ends[-1]
            # Timing confidence annotates the sentence; it never splits text.
            result.append(block)
            pos=stop
    return result
