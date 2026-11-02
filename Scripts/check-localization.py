from pathlib import Path
import re, json

def string_end(s, i):
    triple=s.startswith('"""', i); mark='"""' if triple else '"'; j=i+len(mark)
    while j<len(s):
        if s.startswith(mark,j):return j+len(mark)
        if s.startswith('\\(',j):j=balanced(s,j+1);continue
        if s[j]=='\\':j+=2
        else:j+=1
    raise ValueError(s[i:i+80])

def balanced(s,i):
    depth=1;j=i+1
    while j<len(s):
        if s[j]=='"':j=string_end(s,j);continue
        if s[j]=='(':depth+=1
        if s[j]==')':
            depth-=1
            if depth==0:return j+1
        j+=1
    raise ValueError('unbalanced')

def argument_end(s,i):
    j=i;stack=[]
    while j<len(s):
        if s[j]=='"':j=string_end(s,j);continue
        if s[j] in '([{':stack.append(s[j])
        elif s[j] in ')]}':
            if not stack:return j
            stack.pop()
        elif s[j]==',' and not stack:return j
        j+=1
    return j

def literal_key(literal):
    if literal.startswith('"""'):return None
    value=literal[1:-1];out='';i=0;n=0
    while i<len(value):
        if value.startswith('\\(',i):
            end=balanced(value,i+1);out+='{'+str(n)+'}';n+=1;i=end
        elif value[i]=='\\' and i+1<len(value):
            out+={'n':'\n','t':'\t','r':'\r','"':'"','\\':'\\'}.get(value[i+1],value[i+1]);i+=2
        else:out+=value[i];i+=1
    return out


# The canonical language is Chinese; this audit covers UI and core status/error literals.
# Optional retired intelligence engines retain their own strings and are not exposed in this product.
SKIP = {'Localization.swift','MeetingIntelligence.swift','GemmaRuntime.swift','OptionalModelStore.swift','OptionalModelCatalog.swift'}
EXEMPT = {r'^\u53d1\u8a00\u4eba [0-9]+$'.encode().decode('unicode_escape')}
root = Path(__file__).resolve().parents[1]
catalog = json.loads((root/'Resources/Localization/en.json').read_text(encoding='utf-8'))
failures=[]; candidates=set()
for path in (root/'Sources').glob('*.swift'):
    if path.name in SKIP: continue
    source=path.read_text();i=0
    while i<len(source):
        if source.startswith('//',i):
            end=source.find('\n',i);i=len(source) if end<0 else end;continue
        if source.startswith('/*',i):
            end=source.find('*/',i+2);i=len(source) if end<0 else end+2;continue
        if source[i]=='"':
            end=string_end(source,i);key=literal_key(source[i:end]);i=end
            if key and re.search('[\u4e00-\u9fff]',key) and key not in EXEMPT:
                candidates.add(key)
                if key not in catalog: failures.append(f'{path.name}: missing {key!r}')
        else:i+=1
for key,value in catalog.items():
    if not isinstance(value,str) or not value.strip():failures.append(f'Empty translation: {key!r}')
    if sorted(re.findall(r'\{\d+\}',key))!=sorted(re.findall(r'\{\d+\}',value)):
        failures.append(f'Placeholder mismatch: {key!r}')
    if re.search('[\u4e00-\u9fff]',value): failures.append(f'Untranslated English value: {key!r}')
if failures:
    raise SystemExit('\n'.join(failures))
print(f'PASS: {len(candidates)} canonical literals covered; {len(catalog)} English entries; placeholders preserved')
