import importlib.util,io,json,pathlib,struct,sys,tempfile,types,unittest
from unittest.mock import patch

ROOT=pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'Native/QwenRuntime'))
from inference_policy import token_budget,validate_clip,generate_complete

class PolicyTests(unittest.TestCase):
    def test_transport_limits_and_exact_coverage(self):
        for seconds in [6,24,45,60,120,240]:
            validate_clip(dict(frames=seconds*16000,start=500,end=500+seconds))
        validate_clip(dict(frames=300*16000,start=0,end=300),300)
        for row in [dict(frames=480000,start=0,end=60),dict(frames=16000,start=0,end=2),dict(frames=True,start=0,end=1),dict(frames=16000,start=float('nan'),end=1),dict(frames=241*16000,start=0,end=241)]:
            with self.assertRaises(ValueError):validate_clip(row)
    def test_budget_is_separate_from_audio_length(self):
        self.assertEqual([token_budget(x) for x in [24,45,60,120,240]],[512,848,1088,2048,3968])
        with self.assertRaises(ValueError):token_budget(1200)
    def test_decoder_rejects_partial_results(self):
        class Fake:
            def generate(self,**kwargs):
                self.kwargs=kwargs
                return types.SimpleNamespace(generation_tokens=self.tokens,segments=self.segments,text='kept')
        model=Fake();model.tokens=100;model.segments=[dict(start=0,end=120)]
        generate_complete(model,bytearray(120*16000),language='Chinese')
        self.assertGreater(model.kwargs['chunk_duration'],120);self.assertEqual(model.kwargs['max_tokens'],2048)
        model.tokens=2048
        with self.assertRaises(ValueError):generate_complete(model,bytearray(120*16000),language='Chinese')
        model.tokens=100;model.segments=[dict(start=0,end=30),dict(start=30,end=120)]
        with self.assertRaises(ValueError):generate_complete(model,bytearray(120*16000),language='Chinese')
        model.segments=[dict(start=0,end=30)]
        with self.assertRaises(ValueError):generate_complete(model,bytearray(120*16000),language='Chinese')
    def test_failure_preserves_existing_result(self):
        import worker
        import numpy as np
        class Fake:
            def generate(self,**kwargs):return types.SimpleNamespace(generation_tokens=kwargs['max_tokens'],segments=[dict(start=0,end=60)],text='TRUNCATED')
        with tempfile.TemporaryDirectory() as directory:
            root=pathlib.Path(directory);output=root/'result.json';output.write_text('ORIGINAL')
            hints=root/'hints.json';hints.write_text('{"words":[],"context":""}')
            header=json.dumps(dict(frames=60*16000,start=0,end=60)).encode();data=struct.pack('<I',len(header))+header+np.zeros(60*16000,dtype='<f4').tobytes()
            with patch.object(sys,'stdin',types.SimpleNamespace(buffer=io.BytesIO(data))),patch.dict(sys.modules,{'mlx.core':types.SimpleNamespace(clear_cache=lambda:None,device_info=lambda:{'memory_size':16*1024**3,'max_recommended_working_set_size':12*1024**3},set_memory_limit=lambda _:None,set_cache_limit=lambda _:None),'mlx_audio.stt':types.SimpleNamespace(load=lambda _:Fake())}):
                with self.assertRaises(ValueError):worker.transcribe_stream(str(root),'zh',str(output),str(hints))
            self.assertEqual(output.read_text(),'ORIGINAL');self.assertFalse(output.with_suffix('.partial').exists())
if __name__=='__main__':unittest.main()
