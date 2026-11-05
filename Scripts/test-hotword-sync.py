"""Run the actual Swift client against an isolated in-memory RecordAI server."""
import os
import pathlib
import selectors
import shutil
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
server = pathlib.Path(os.environ.get("RECORD_AI_SERVER_ROOT", str(root.parent / "recordai" / "server"))).resolve()
node = os.environ.get("RECORD_AI_TEST_NODE") or shutil.which("node")
if not node:
    raise SystemExit("Node.js 22+ is required; set RECORD_AI_TEST_NODE to its executable.")
with tempfile.TemporaryDirectory(prefix="recordai-hotword-e2e-") as temp:
    binary = str(pathlib.Path(temp) / "account-e2e")
    subprocess.run(["xcrun", "swiftc", "-warnings-as-errors", "-swift-version", "5", "-parse-as-library",
                    "Sources/PersonalHotwords.swift", "Sources/HotwordSync.swift", "Sources/TalkTuckAccountStore.swift",
                    "Tests/HotwordSyncE2E.swift", "Tests/HotwordTestStubs.swift", "-o", binary], cwd=root, check=True)
    process = subprocess.Popen([node, "--import", "tsx", "test/support/hotword-e2e-server.ts"],
                               cwd=server, stdout=subprocess.PIPE, text=True)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            if not selector.select(timeout=15):
                raise RuntimeError("Isolated server did not become ready within 15 seconds")
        url = process.stdout.readline().strip()
        if not url.startswith("http://127.0.0.1:"):
            raise RuntimeError("Isolated server did not start: " + url)
        subprocess.run([binary, url], check=True, timeout=60)
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
