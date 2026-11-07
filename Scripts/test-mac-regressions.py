#!/usr/bin/env python3
"""Compile one frozen Mac candidate and run existing regressions in separate processes.

All generated files require an explicit output directory. Optional backend tests
use local in-memory SQLite fixtures, synthetic accounts and no real SMS/ASR.
Optional speech tests use installed engines/models and synthesized audio only.
"""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import plistlib
import selectors
import signal
import shutil
import subprocess
import sys
import time
import wave
from urllib.parse import urlparse

CORE = [
    ("seam-recovery", "ProgressiveSeamRecoverySmoke", True),
    ("window-recovery", "ProgressiveWindowRecoverySmoke", False),
    ("progressive", "ProgressiveTranscriptionSmoke", True),
    ("multilingual", "MultilingualSentenceSmoke", False),
    ("paragraph-policy", "TranscriptParagraphPolicySmoke", False),
    ("appearance", "AppAppearanceSmoke", False), ("window-policy", "ASRWindowPolicySmoke", False), ("live-refinement", "LivePreviewRefinerSmoke", False), ("hotwords", "PersonalHotwordsSmoke", True),
    ("language", "TranscriptionLanguageSmoke", False), ("localization", "LocalizationSmoke", False),
    ("library", "LibrarySmoke", False), ("agent-data", "AgentDataSmoke", False),
    ("speaker-edit", "SpeakerEditingSmoke", False), ("paragraph-playback", "ParagraphPlaybackSmoke", True),
    ("organization", "OrganizationSmoke", False), ("recording-domain", "RecordingDomainSmoke", False),
    ("mini", "MiniRecordingSmoke", True), ("recording-browsing", "RecordingBrowsingSmoke", True),
    ("capture-polish", "CapturePolishSmoke", True), ("recording-profile", "RecordingProfileSmoke", False),
    ("cold-start", "AgentColdStartSmoke", True),
]
EXTRA = [
    ("progressive-real", "ProgressiveRealPipelineSmoke", True),
    ("cli-fixture", "AgentCLIFixture", False), ("account", "TalkTuckAccountSmoke", True),
    ("automatic-sync", "LibraryAutomaticSyncSmoke", True), ("text-sync", "LibrarySyncSmoke", True),
    ("remote-edit", "LibrarySyncRemoteEditSmoke", True), ("audio-retry", "LibraryAudioSmoke", True),
    ("hotword-sync", "HotwordSyncE2E", True), ("offline-asr", "OfflineASR", False),
    ("format-asr", "RecordingFormatSmoke", True), ("append-asr", "RecordingAppendSmoke", True),
    ("canonical-capture", "MacCanonicalCaptureSmoke", True), ("canonical-long", "MacCanonicalLongCaptureSmoke", True),
    ("segmented-manifest", "MacSegmentedManifestSmoke", False), ("segmented-track", "MacSegmentedTrackSmoke", False),
    ("canonical-player", "MeetingAudioPlayerSmoke", True), ("canonical-transcription", "CanonicalTranscriptionSmoke", False),
    ("offline-windows", "OfflineWindowSmoke", False), ("canonical-windows", "CanonicalOfflineWindowSmoke", False),
    ("window-speakers", "OfflineWindowSpeakerSmoke", False), ("canonical-sync", "CanonicalAudioSyncSmoke", True),
    ("canonical-real-asr", "CanonicalRealASRSmoke", False), ("existing-archives", "ExistingArchiveReadSmoke", True), ("long-windows", "ASRLongWindowSmoke", False), ("profile-long-windows", "ASRProfileLongWindowSmoke", False), ("real-window-pipeline", "ASRWindowRealPipelineSmoke", False), ("live-long-utterance", "LivePreviewLongUtteranceSmoke", False), ("live-cache", "LiveRefinementCacheSmoke", False),
]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--existing-library", type=Path, help="Read-only source; selected archive recordings are copied to the output root")
    parser.add_argument("--server-repo", type=Path)
    parser.add_argument("--node", type=Path)
    parser.add_argument("--engine-dir", type=Path)
    parser.add_argument("--model-root", type=Path)
    parser.add_argument("--reuse-long-recording-result",type=Path,help="Prior passing run; reuse only when the long-capture test and all recording inputs are unchanged")
    parser.add_argument("--reuse-compiled-from",type=Path,help="Reuse a compiled test app only when every source and test input hash matches")
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[1]
    run = args.output_root.resolve()
    run.mkdir(parents=True, exist_ok=False)
    for name in ["build", "tmp", "cache", "evidence", "fixtures"]: (run/name).mkdir()
    env = dict(os.environ, TMPDIR=str(run/"tmp")+"/", XDG_CACHE_HOME=str(run/"cache"),
               SWIFT_USE_OLD_DRIVER="1", PYTHONDONTWRITEBYTECODE="1", RECORD_AI_TRANSCRIPTION_TMP_ROOT=str(run/"tmp"), NODE_COMPILE_CACHE=str(run/"cache/node"),
               CLANG_MODULE_CACHE_PATH=str(run/"cache/clang"), SWIFT_MODULECACHE_PATH=str(run/"cache/swift"),
               HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_HOME=str(run/"cache/huggingface"))
    if args.node: env["PATH"] = str(args.node.resolve().parent)+os.pathsep+env["PATH"]
    results = []
    def call(case, command, *, cwd=source, extra=None, timeout=180, required=False):
        started = time.monotonic(); log = run/"evidence"/(case+".log")
        try:
            with log.open("w") as output:
                result = subprocess.run([str(x) for x in command], cwd=cwd, env=dict(env, **(extra or {})),
                                        stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
            status = "PASS" if result.returncode == 0 else "FAIL"
            detail = {"exitCode": result.returncode}
        except subprocess.TimeoutExpired:
            status, detail = "FAIL", {"reason": "TIMEOUT"}
        results.append(dict(case=case, status=status, seconds=round(time.monotonic()-started, 2), log=str(log), **detail))
        (run/"results.json").write_text(json.dumps(results, indent=2))
        print(case+": "+status, flush=True)
        if required and status != "PASS": raise RuntimeError(case+" failed; see "+str(log))
        return status == "PASS"
    specs = CORE+EXTRA
    frozen = run/"build/frozen"; frozen.mkdir()
    inputs = {}
    for path in sorted((source/"Sources").glob("*.swift")):
        text = path.read_text()
        inputs[str(path.relative_to(source))] = hashlib.sha256(path.read_bytes()).hexdigest()
        if path.name == "CoHearTranscribeApp.swift": text = text.replace("@main\n", "")
        (frozen/path.name).write_text(text)
    test_names = {name for _, name, _ in specs} - {"AgentCLIFixture", "LibrarySyncRemoteEditSmoke", "OfflineASR"}
    test_names.update(["MacRegressionFixtures", "OfflineLocalTranscriptionSmoke"])
    for name in sorted(test_names):
        path = source/"Tests"/(name+".swift")
        inputs[str(path.relative_to(source))] = hashlib.sha256(path.read_bytes()).hexdigest()
        (frozen/("Test-"+name+".swift")).write_text(path.read_text().replace("@main", ""))
    cases = "\n".join('case "'+case+'": '+('try await ' if asynchronous else '' if case in {"appearance", "language", "window-policy", "live-refinement"} else 'try ')+name+'.main()' for case,name,asynchronous in specs)
    (frozen/"Runner.swift").write_text('import Foundation\n@main struct MacRegressionRunner { @MainActor static func main() async throws { switch ProcessInfo.processInfo.environment["TALKTUCK_REGRESSION_CASE"] ?? "" {\n'+cases+'\ndefault: fatalError("Unknown regression case")\n} } }\n')
    app = run/"build/MacRegressions.app"; executable = app/"Contents/MacOS/regressions"
    executable.parent.mkdir(parents=True); (app/"Contents/Resources/Localization").mkdir(parents=True)
    for path in (source/"Resources/Localization").glob("*.json"):
        (app/"Contents/Resources/Localization"/path.name).write_bytes(path.read_bytes())
    (app/"Contents/Info.plist").write_bytes(plistlib.dumps(dict(CFBundleIdentifier="com.xsg.talktuck.regressions", CFBundleExecutable="regressions", CFBundlePackageType="APPL")))
    shutil.copy2(source/"Resources/SentenceRules.json",app/"Contents/Resources/SentenceRules.json")
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    canonical_cases = ["canonical-capture","canonical-long","segmented-manifest","segmented-track","canonical-player","canonical-transcription","offline-windows","canonical-windows","window-speakers", "long-windows", "profile-long-windows", "live-long-utterance", "live-cache"]
    plan = ["compile"]+canonical_cases+[x[0] for x in CORE]+["cli-compile", "cli-fixture", "cli-mcp", "group-cli", "localization-catalog", "agent-setup", "speaker-fragments", "sentence-speakers", "multilingual-native", "speaker-timeline", "language-policy", "inference-policy", "alignment-windows", "reporting"]
    if args.server_repo and args.node: plan += ["server-typecheck", "server-contracts", "account", "automatic-sync", "text-offline-seed", "remote-edit", "text-conflict-resolve", "audio-retry", "hotword-sync", "canonical-sync"]
    if args.engine_dir and args.model_root: plan += ["synthesize", "convert", "offline-asr", "format-asr", "append-asr", "synthesize-cantonese", "convert-cantonese", "live-cantonese", "synthesize-english", "english-final-speakers", "canonical-real-asr", "quiet-real-asr"]
    (run/"readiness.json").write_text(json.dumps(dict(commit=commit, inputs=inputs, cases=plan, compiledEntrypoints=[x[0] for x in specs],
        backend="isolated loopback, in-memory SQLite, fake SMS" if args.server_repo else "not selected",
        libraryRoot=str(run/"fixtures"), userLibraryModified=False, hardwareCapture=False), indent=2))
    compiler = ["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", "-target", "arm64-apple-macosx14.0", "-module-cache-path", run/"cache/swift"]
    if args.reuse_compiled_from:
        prior = args.reuse_compiled_from.resolve()
        assert json.loads((prior/"readiness.json").read_text())["inputs"] == inputs, "Compiled test inputs changed"
        checked = next(x for x in json.loads((prior/"results.json").read_text()) if x["case"] == "compile")
        assert checked["status"] == "PASS", "Prior test compile did not pass"
        shutil.copy2(prior/"build/MacRegressions.app/Contents/MacOS/regressions",executable)
        results.append(dict(checked,reusedFrom=str(prior),allInputHashesVerified=True))
        print("compile: PASS (all source and test input hashes match prior run)",flush=True)
    else:
        call("compile", compiler+sorted(frozen.glob("*.swift"))+["-o", executable], timeout=600, required=True)
    def swift(case, *arguments, label=None, network=False, **extra):
        command = [executable, *arguments]
        if not network: command = ["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)", *command]
        return call(label or case, command, extra=dict(TALKTUCK_REGRESSION_CASE=case, **extra), timeout=900 if case == "canonical-long" else 360 if "asr" in case else 90)
    for case, _, _ in CORE:
        arguments = [run/"fixtures"/case] if case in {"cold-start","progressive"} else []
        if case=="window-recovery": arguments=[run/"fixtures"/case,source/"Tests/ProgressiveWindowRecoveryWorkerFake.py"]
        if case=="seam-recovery": arguments=[run/"fixtures"/case,source/"Tests/ProgressiveSeamRecoveryWorkerFake.py"]
        extra = {"TALKTUCK_TEST_AGENT_OUT": str(run/"fixtures/organization-agent")} if case == "organization" else {}
        swift(case, *arguments, **extra)
    for case in canonical_cases:
        if case == "canonical-long" and args.reuse_long_recording_result:
            prior = args.reuse_long_recording_result.resolve()
            readiness = json.loads((prior/"readiness.json").read_text())
            checked = next(x for x in json.loads((prior/"results.json").read_text()) if x["case"] == case)
            dependencies = ["ResilientRecordingJournal", "BalancedWatchSync", "CanonicalAudioReader", "MacSegmentedTrackWriter", "MacSegmentedManifest"]
            paths = ["Sources/"+x+".swift" for x in dependencies]+["Tests/MacCanonicalLongCaptureSmoke.swift"]
            assert checked["status"] == "PASS" and all(inputs[p] == readiness["inputs"][p] for p in paths), "Long-capture evidence does not match current recording code"
            results.append(dict(checked,reusedFrom=str(prior),inputHashesVerified=paths))
            (run/"results.json").write_text(json.dumps(results,indent=2))
            print(case+": PASS (unchanged recording inputs; prior run)",flush=True)
            continue
        directory = run/"fixtures"/case; directory.mkdir()
        arguments = [directory]
        if case == "canonical-transcription": arguments += [source/"Tests/CanonicalASRWorkerFake.py"]
        if case == "canonical-windows": arguments += [source/"Tests/OfflineWindowWorkerFake.py"]
        if case == "window-speakers": arguments += [source/"Tests/OfflineWindowSpeakerWorkerFake.py"]
        if case == "long-windows": arguments += [source/"Tests/ASRLongWindowWorkerFake.py"]
        if case == "profile-long-windows": arguments += [source/"Tests/ASRProfileLongWindowWorkerFake.py"]
        if case == "live-long-utterance": arguments += [source/"Tests/LivePreviewLongUtteranceWorkerFake.py"]
        if case == "live-cache": arguments += [source/"Tests/LiveRefinementCacheWorkerFake.py"]
        swift(case,*arguments)
    cli = run/"build/talktuck"
    cli_compiler = [x for x in compiler if x != "-parse-as-library"]
    call("cli-compile", cli_compiler+[source/"Sources/AgentSchema.swift", source/"Sources/TalkTuckControl.swift", source/"Sources/AgentSetup.swift", source/"Native/AgentCLI/main.swift", "-o", cli], required=True)
    if swift("cli-fixture", run/"fixtures/cli"):
        call("cli-mcp", [sys.executable, source/"Tests/AgentCLIIntegration.py", cli, run/"fixtures/cli"])
    if (run/"fixtures/organization-agent").exists(): call("group-cli", [sys.executable, source/"Tests/OrganizationCLIIntegration.py", cli, run/"fixtures/organization-agent"])
    for case, script in [("localization-catalog", "Scripts/check-localization.py"), ("agent-setup", "Scripts/test-agent-setup.py"), ("speaker-fragments", "Tests/SpeakerAttributionSmoke.py"), ("speaker-timeline", "Tests/SpeakerTimelineSmoke.py"), ("language-policy", "Tests/LanguagePolicySmoke.py"), ("inference-policy", "Tests/InferencePolicySmoke.py"), ("alignment-windows", "Tests/AlignmentWindowsSmoke.py")]:
        call(case, [sys.executable, source/script])
    call("multilingual-native", [sys.executable, source/"Tests/MultilingualSentenceSmoke.py"])
    call("sentence-speakers", [sys.executable, source/"Tests/SentenceSpeakerSmoke.py"])
    call("reporting", [sys.executable, "-m", "unittest", "discover", "-s", "Tests/reporting", "-v"])
    @contextlib.contextmanager
    def fixture(script, label, audio=False):
        server = args.server_repo.resolve()/"server"
        log = (run/"evidence"/(label+"-server.log")).open("w")
        process = subprocess.Popen([str(args.node.resolve()), "node_modules/tsx/dist/cli.mjs", script], cwd=server,
            env=dict(env, SYNC_TEST_PORT="0", SYNC_TEST_AUDIO="1" if audio else "0"), stdout=subprocess.PIPE, stderr=log, text=True, start_new_session=True)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                if not selector.select(timeout=20): raise RuntimeError("Loopback fixture did not start")
            endpoint = process.stdout.readline().strip(); url = urlparse(endpoint)
            if url.scheme != "http" or url.hostname != "127.0.0.1" or not url.port: raise RuntimeError("Unexpected fixture endpoint")
            yield endpoint
        finally:
            if process.poll() is None: os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=15); log.close()
    if args.server_repo and args.node:
        server = args.server_repo.resolve()/"server"
        call("server-typecheck", [args.node, "node_modules/typescript/bin/tsc", "--noEmit"], cwd=server)
        call("server-contracts", [args.node, "node_modules/tsx/dist/cli.mjs", "--test", "test/library-sync.test.ts", "test/library-audio.test.ts", "test/mac-account.test.ts"], cwd=server)
        with fixture("test/support/mac-account-server.ts", "library", audio=True) as endpoint:
            swift("account", endpoint, network=True)
            swift("automatic-sync", endpoint, run/"fixtures/automatic-sync", network=True)
            swift("canonical-sync", endpoint, run/"fixtures/canonical-sync", network=True)
            if swift("text-sync", "seed", run/"fixtures/text-sync", endpoint, label="text-offline-seed", network=True):
                if swift("remote-edit", endpoint, network=True): swift("text-sync", "finish", run/"fixtures/text-sync", endpoint, label="text-conflict-resolve", network=True)
            swift("audio-retry", "seed", run/"fixtures/audio-retry", endpoint, network=True)
        with fixture("test/support/hotword-e2e-server.ts", "hotwords") as endpoint:
            swift("hotword-sync", endpoint, network=True)
    if args.engine_dir and args.model_root:
        engine = args.engine_dir.resolve(); models = args.model_root.resolve(); media = run/"fixtures/media"; media.mkdir()
        call("synthesize", ["say", "-v", "Tingting", "-r", "155", "-o", media/"speech.aiff", "今天的会议将测试本地转录，请保留原始录音。"])
        call("convert", ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", media/"speech.aiff", media/"speech.wav"])
        swift("canonical-real-asr", media, media/"speech.wav", models/"Qwen3ASR", engine/"qwen-asr")
        swift("canonical-real-asr", media, media/"speech.wav", models/"Qwen3ASR", engine/"qwen-asr", "--quiet", label="quiet-real-asr")
        swift("offline-asr", engine/"qwen-asr", models/"Qwen3ASR", media/"speech.wav", media/"offline.json")
        swift("format-asr", engine/"qwen-asr", models/"Qwen3ASR", media/"speech.aiff", media/"formats")
        # RecordingAppendSmoke's fixed fixture has a 14-second first part.
        with wave.open(str(media/"speech.wav"), "rb") as stream:
            params = stream.getparams(); frames = stream.readframes(stream.getnframes())
        assert params.nchannels == 1 and params.sampwidth == 2 and params.framerate == 16000
        assert len(frames) <= 14*16000*2, "Synthesis is longer than the existing append fixture"
        with wave.open(str(media/"append.wav"), "wb") as stream:
            stream.setparams(params); stream.writeframes(frames+bytes(14*16000*2-len(frames)))
        swift("append-asr", engine/"qwen-asr", models/"Qwen3ASR", media/"append.wav")
        call("synthesize-cantonese", ["say", "-v", "Sinji", "-r", "155", "-o", media/"cantonese.aiff", "大家好，我哋今日喺公司开会，请帮我记低重点，唔好漏咗啲重要资料，听日朝早九点再倾。"])
        call("convert-cantonese", ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", media/"cantonese.aiff", media/"cantonese.wav"])
        call("live-cantonese", [sys.executable, source/"Scripts/test-live-cantonese.py", "--engine", engine/"qwen-asr", "--model", models/"Qwen3ASR", "--audio", media/"cantonese.wav", "--output", media/"live-cantonese", "--repeats", "2"])
        call("synthesize-english", ["say", "-v", "Samantha", "-r", "155", "-o", media/"english.aiff", "Welcome to the TalkTuck test. Please keep the original recording and organize it into a group. An external agent can read the final transcript."])
        swift("localization", engine/"qwen-asr", models/"Qwen3ASR", media/"english.aiff", "en", media/"english-result", label="english-final-speakers")
    if args.existing_library:
        plan.append("existing-archives")
        copy = run/"fixtures/existing-library"; (copy/"Meetings").mkdir(parents=True)
        source_root = args.existing_library.resolve()
        for metadata in (source_root/"Meetings").glob("*/meeting.json"):
            value = json.loads(metadata.read_text())
            if not any(x.endswith(".aacarchive") for x in value.get("audioFiles",[])): continue
            destination = copy/"Meetings"/metadata.parent.name
            shutil.copytree(metadata.parent,destination,symlinks=True)
        swift("existing-archives",copy)
    seen = {x["case"] for x in results}
    for case in plan:
        if case not in seen: results.append(dict(case=case, status="NOT_RUN", reason="Prerequisite did not pass"))
    summary = dict(commit=commit, passed=sum(x["status"]=="PASS" for x in results), failed=sum(x["status"]=="FAIL" for x in results), notRun=sum(x["status"]=="NOT_RUN" for x in results),
        results=results, excluded=["real microphone/system capture", "production backend", "physical iPhone", "external third-party publishing"])
    (run/"summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps({k:v for k,v in summary.items() if k!="results"}), flush=True)
    return 1 if summary["failed"] or summary["notRun"] else 0

if __name__ == "__main__": sys.exit(main())
