"""实际CLI和MCP的只读端到端验收；仅合成数据。"""
import json, subprocess, hashlib, pathlib, sys
cli, root = sys.argv[1:]
root = pathlib.Path(root)
id = '11111111-2222-3333-4444-555555555555'
metadata = root / 'Meetings' / id / 'meeting.json'
before = hashlib.sha256(metadata.read_bytes()).hexdigest()
def run(*args):
    return subprocess.check_output([cli, '--root', str(root / 'AgentData'), *args], text=True)
rows = json.loads(run('list')); assert rows[0]['id'] == id and rows[0]['ready']
record = json.loads(run('read', id)); assert record['finalText'] == '你好，世界！' and 'livePreview' not in record
assert '旧笔记' not in run('read', id) and '旧总结' not in run('read', id)
assert json.loads(run('read', id, '--include-preview'))['previewIsFinal'] is False
assert run('read', id, '--format', 'txt') == record['finalText']
assert '转录正文' in run('read', id, '--format', 'md')
audio = json.loads(run('audio', id)); assert audio[0]['available'] and pathlib.Path(audio[0]['path']).is_file()
assert json.loads(run('changes', '--since', '0'))['events']
requests = [
 {'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-03-26'}},
 {'jsonrpc':'2.0','method':'notifications/initialized'},
 {'jsonrpc':'2.0','id':2,'method':'tools/list'},
 {'jsonrpc':'2.0','id':3,'method':'tools/call','params':{'name':'get_recording','arguments':{'id':id}}},
 {'jsonrpc':'2.0','id':4,'method':'tools/call','params':{'name':'get_transcript','arguments':{'id':id,'includePreview':True}}},
 {'jsonrpc':'2.0','id':5,'method':'resources/read','params':{'uri':f'cohear://recordings/{id}'}},
 {'jsonrpc':'2.0','id':6,'method':'tools/call','params':{'name':'get_recording','arguments':{'id':'../../private'}}},
 {'jsonrpc':'2.0','id':7,'method':'tools/call','params':{'name':'get_changes','arguments':{'since':999}}},
 {'jsonrpc':'2.0','id':8,'method':'delete_recording'},
]
p = subprocess.run([cli, '--root', str(root/'AgentData'), 'mcp'],input='\n'.join(map(json.dumps, requests))+'\n',text=True,capture_output=True,check=True)
responses = {x['id']:x for x in map(json.loads,p.stdout.splitlines())}
assert len(responses)==8 and not p.stderr
assert responses[1]['result']['protocolVersion']=='2025-03-26'
assert all(x['annotations']['readOnlyHint'] for x in responses[2]['result']['tools'])
assert 'livePreview' not in json.loads(responses[3]['result']['content'][0]['text'])
assert json.loads(responses[4]['result']['content'][0]['text'])['previewIsFinal'] is False
assert responses[6]['result']['isError'] is True
assert json.loads(responses[7]['result']['content'][0]['text'])['resyncRequired'] is True
assert responses[8]['error']['code']==-32601
assert hashlib.sha256(metadata.read_bytes()).hexdigest()==before
print('PASS: CLI各格式/音频/游标、MCP初始化/只读工具/资源/草稿选择/非法UUID/未支持写操作、原始会议哈希不变')
