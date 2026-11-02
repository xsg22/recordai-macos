"""Run the real CLI and stdio MCP against publisher-generated isolated data."""
import json,subprocess,sys
from pathlib import Path
cli,root=sys.argv[1:]
ids=json.loads((Path(root)/'fixture.json').read_text())
def run(*args):
    return json.loads(subprocess.check_output([cli,'--root',root,*args],text=True))
rows=run('list','--group',ids['groupID'])
assert {r['id'] for r in rows}=={ids['recordingID'],ids['otherID']}
assert [r['id'] for r in run('list','--query','测试正文')]==[ids['recordingID']]
retired=subprocess.run([cli,'--root',root,'list','--tag',ids['groupID']],capture_output=True,text=True)
assert retired.returncode != 0, 'Removed options must fail rather than return an unfiltered library'
assert run('list','--ungrouped')==[]
assert len(run('list'))==2
record=run('read',ids['recordingID'])
assert record['organization']['group']['name']=='项目'
assert 'tags' not in record['organization'] and all('tags' not in r['organization'] for r in rows)
assert 'bookmarks' not in record['organization']
assert run('changes','--since','0')['events'][-1]['kind']=='metadata'
requests=[
 {'jsonrpc':'2.0','id':1,'method':'tools/list'},
 {'jsonrpc':'2.0','id':2,'method':'tools/call','params':{'name':'list_recordings','arguments':{'groupId':ids['groupID']}}},
 {'jsonrpc':'2.0','id':3,'method':'tools/call','params':{'name':'list_recordings','arguments':{'tagIds':'invalid'}}},
 {'jsonrpc':'2.0','id':4,'method':'tools/call','params':{'name':'get_recording','arguments':{'id':ids['recordingID']}}},
]
process=subprocess.run([cli,'--root',root,'mcp'],input='\n'.join(json.dumps(r) for r in requests)+'\n',capture_output=True,text=True,check=True)
responses=[json.loads(line) for line in process.stdout.splitlines()]
assert len(responses)==4
schema=next(t['inputSchema'] for t in responses[0]['result']['tools'] if t['name']=='list_recordings')
assert schema['required']==[] and 'tagIds' not in schema['properties']
read=lambda response:json.loads(response['result']['content'][0]['text'])
assert {r['id'] for r in read(responses[1])}=={ids['recordingID'],ids['otherID']}
assert 'error' in responses[2] or responses[2].get('result',{}).get('isError') is True
assert 'bookmarks' not in read(responses[3])['organization']
assert not (Path(root)/'commands').exists(), 'Read-only queries must not request recording'
print('PASS: CLI/MCP 查询、分组筛选及移除标签接口、正文检索和时间点移除、旧 list/read 兼容、独立 metadata 事件、旧标签参数拒绝，无录音副作用。')
