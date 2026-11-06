"""Store model speaker posteriors, including bounded retrospective FIFO updates.

This changes neither speaker IDs nor model probabilities. Real sample offsets
keep frame rounding from accumulating across long recordings.
"""
import math

class SpeakerTimeline:
    def __init__(self,frame_duration):
        self.step=frame_duration;self.scores=[];self.times=[]
    def append(self,scores,offset,duration,revised):
        if not math.isfinite(offset)or duration<=0:raise ValueError('Invalid diarization chunk')
        width=len(scores[0])if scores else len(self.scores[0])if self.scores else 4
        if not 1<=width<=4:raise ValueError('Invalid speaker slots')
        for row in scores:
            if len(row)!=width or any(not math.isfinite(p)or not 0<=p<=1 for p in row):raise ValueError('Invalid speaker probabilities')
        for i,row in enumerate(scores):
            self.times.append((offset+min(duration,i*self.step),offset+min(duration,(i+1)*self.step)))
            self.scores.append(list(row))
        if len(revised)>len(self.scores):raise ValueError('Speaker FIFO exceeds recorded frames')
        begin=len(self.scores)-len(revised)
        for i,row in enumerate(revised):
            if len(row)!=width or any(not math.isfinite(p)or not 0<=p<=1 for p in row):raise ValueError('Invalid revised probabilities')
            self.scores[begin+i]=list(row)
    def frames(self):
        """Keep soft, globally identified evidence for sentence attribution."""
        return [[start,end,*scores] for (start,end),scores in zip(self.times,self.scores) if end>start]
    def turns(self,threshold=.5,min_duration=.12,merge_gap=.16):
        result=[]
        if not self.scores:return result
        for who in range(len(self.scores[0])):
            intervals=[];active=None
            for (start,end),scores in zip(self.times,self.scores):
                if end>start and scores[who]>=threshold:
                    if active is None:active=[start,end]
                    else:active[1]=end
                elif active is not None:intervals.append(active);active=None
            if active is not None:intervals.append(active)
            merged=[]
            for start,end in intervals:
                if merged and start-merged[-1][1]<=merge_gap+1e-8:merged[-1][1]=end
                else:merged.append([start,end])
            result.extend(dict(start=start,end=end,speaker=str(who))for start,end in merged if end-start>=min_duration-1e-8)
        return sorted(result,key=lambda x:x['start'])
