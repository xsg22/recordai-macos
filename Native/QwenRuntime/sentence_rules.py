"""Locale-neutral sentence policy shared with the Mac reading fallback."""
import json,pathlib,sys,re,unicodedata
root=pathlib.Path(getattr(sys,'_MEIPASS',pathlib.Path(__file__).resolve().parents[2]/'Resources'))
RULES=json.loads((root/'SentenceRules.json').read_text())
CJK=re.compile(r'[\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af\u0e00-\u0fff\u1000-\u109f\u1780-\u17ff]')

def sentence_ends(text):
    ends=set();n=len(text);terminals=set(RULES['terminals']);closers=set(RULES['closers'])
    for i,c in enumerate(text):
        if c not in terminals:continue
        if c=='.':
            if i+1<n and text[i+1].isascii() and text[i+1].isalnum():continue # decimals, versions, hosts, initialisms
            word=re.search(r"[\w.]+$",text[:i],re.UNICODE)
            token=word[0].casefold()if word else ''
            following=text[i+1:].lstrip(RULES['closers'])
            if following and (token in RULES['abbreviations'] or re.fullmatch(r'(?:[^\W\d_]\.)*[^\W\d_]',token) and len(token)<=7):continue
        j=i+1
        while j<n and(text[j]in closers or text[j]in terminals):j+=1
        ends.add(j)
    return ends

def units(text,words=False):
    if words:
        count=0;inside=False
        for c in text:
            letter=c.isalnum()
            if letter and not inside:count+=1
            inside=letter or inside and (c in "'’-" or unicodedata.category(c).startswith('M'))
        return count
    return sum(c.isalnum()for c in text)

def word_language(text):return not CJK.search(text)
