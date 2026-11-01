#!/usr/bin/env python3
"""Gate an explicitly requested functional prerelease without claiming UI sign-off."""
import hashlib
import json
from pathlib import Path
import plistlib
import sys

ROOT = Path(__file__).resolve().parents[1]


def digest(paths):
    value = hashlib.sha256()
    for path in sorted(paths):
        value.update(str(path.relative_to(ROOT)).encode())
        value.update(b"\0")
        value.update(path.read_bytes())
        value.update(b"\0")
    return value.hexdigest()


def validate(report, regression, contracts, package, binding, source_hash, runtime_hash, version):
    issues = []
    direct = report.get("direct_entry_recheck", {})
    if any(item.get("sourceDigest") != source_hash for item in [direct, regression, contracts, package, binding]):
        issues.append("主功能证据没有绑定当前应用源码")
    if binding.get("runtimeInputDigest") != runtime_hash:
        issues.append("运行时输入与实测版本不一致")
    if binding.get("embeddedAsrSha256") != package.get("embedded_asr_sha256"):
        issues.append("实测引擎与候选包引擎不一致")
    if report.get("app_version") != version or package.get("version") != version:
        issues.append("实测或安装包版本不一致")
    if not all(direct.get(key) is True for key in ["direct_start_button_verified", "clicked_direct_button", "completed", "speaker_analysis_completed", "source_preserved"]):
        issues.append("缺真实客户端导入和内置引擎完成证据")
    if direct.get("speaker_sequence") != ["0", "1", "0", "1"] or report.get("paragraph_count") != 4:
        issues.append("发言人和分段验证不完整")
    if not report.get("segment_playback", {}).get("passed"):
        issues.append("缺分段播放验证")
    if not all(report.get("manual_correction", {}).get(key) is True for key in ["saved", "timestamps_speakers_ids_and_audio_unchanged", "raw_subtitles_unchanged"]):
        issues.append("缺人工校正与原始资料保全验证")
    if not all(report.get("export", {}).get(key) is True for key in ["markdown_original", "markdown_corrected", "speaker_and_time_markers", "original_srt"]):
        issues.append("缺实际导出验证")
    if regression.get("exit_code") != 0 or regression.get("regression_groups") != 14 or contracts.get("exit_code") != 0 or len(contracts.get("tests", [])) != 8:
        issues.append("22 组回归证据不完整")
    if package.get("script_exit_code") != 0:
        issues.append("本地候选包内容校验未通过")
    return issues


def main():
    evidence = ROOT / "Docs/design-v2/validation"
    read = lambda name: json.loads((evidence / (name + ".json")).read_text())
    binding = read("functional-release-binding")
    source_hash = digest(list((ROOT / "Sources").glob("*.swift")) + [p for p in (ROOT / "Resources").glob("*") if p.is_file()])
    runtime_paths = [ROOT / name for name in binding["runtimeInputs"]]
    version = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())["CFBundleShortVersionString"]
    issues = validate(read("import-e2e/result"), read("data-regression"), read("ui-contracts"), read("candidate-package"), binding, source_hash, digest(runtime_paths), version)
    for name in ["03-transcribed.jpg", "05-segment-ended.ax.txt", "06-corrected.ax.txt", "07-direct-entry.jpg", "09-direct-completed.jpg", "合成会议导入验收-原始识别.md", "合成会议导入验收-人工校正.md", "合成会议导入验收.srt"]:
        if not (evidence / "import-e2e" / name).is_file():
            issues.append("缺实测附件：" + name)
    if issues:
        print("功能验证版门禁失败：\n- " + "\n- ".join(issues), file=sys.stderr)
        return 1
    print("PASS: 当前源码、运行时输入、真实音频导入/分人/回放/校正/导出、22 组回归及候选包校验已绑定。")
    print("仅允许功能验证 prerelease；不表示全部 UI 验收通过。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
