import importlib.util
import sys
from pathlib import Path

path = Path(__file__).resolve().parents[1] / "Native/QwenRuntime/worker.py"
sys.path.insert(0, str(path.parent))
spec = importlib.util.spec_from_file_location("hotword_worker", path)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)

words = ["TalkTuck", "TalkTuck"] + ["词条" + str(i) for i in range(20)]
selected = worker.select_hotwords(words, "正在讨论 talktuck 项目")
assert len(selected) == 12
assert selected[0] == "TalkTuck"
assert "TalkTuck" not in selected
assert worker.select_hotwords([], "anything") == []
assert worker.select_hotwords(["TalkTuck", "TalkTuck"], "") == ["TalkTuck", "TalkTuck"]
print("hotword selection smoke passed")
