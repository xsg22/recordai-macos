#!/usr/bin/env python3
"""Require evidence for every design page before publishing a release."""
import argparse
import hashlib
import json
from pathlib import Path
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


def evidence(value):
    if not isinstance(value, str) or not value.strip():
        return None
    path = (ROOT / value).resolve()
    if not path.is_relative_to(ROOT) or not path.is_file() or not path.stat().st_size:
        return None
    return path


def screenshot_image(path):
    if path is None:
        return False
    payload = path.read_bytes()
    if len(payload) < 1024:
        return False
    return ((path.suffix.lower() == ".png" and payload.startswith(b"\x89PNG\r\n\x1a\n"))
            or (path.suffix.lower() in {".jpg", ".jpeg"} and payload.startswith(b"\xff\xd8\xff") and payload.endswith(b"\xff\xd9")))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", action="store_true", help="report pending work without failing")
    parser.add_argument("--digests", action="store_true", help="print current review version hashes")
    args = parser.parse_args()
    source_hash = digest(list((ROOT / "Sources").glob("*.swift")) + [p for p in (ROOT / "Resources").glob("*") if p.is_file()])
    design_hash = digest([ROOT / "Docs/design-v2" / p for p in ["manifest.json", "design.js", "index.html", "logo.png"]])
    if args.digests:
        print(json.dumps({"sourceDigest": source_hash, "designDigest": design_hash}, indent=2))
        return 0
    spec = json.loads((ROOT / "Docs/design-v2/manifest.json").read_text())
    acceptance = json.loads((ROOT / "Docs/design-v2/acceptance.json").read_text())
    entries = acceptance["pages"]
    expected = {page["id"]: page for page in spec["pages"]}
    problems = []
    if len(entries) != len(expected) or {p["id"] for p in entries} != set(expected):
        problems.append("设计册和验收记录的页面编号不完全一致，或存在重复项")
    passed = 0
    for page in entries:
        issues = []
        if not evidence(page.get("implementation")):
            issues.append("缺现存实现文件")
        if page.get("status") != "passed":
            issues.append("待验收")
        if page.get("checks") != expected.get(page["id"], {}).get("checks"):
            issues.append("检查项遗漏或被修改")
        screenshot = evidence(page.get("screenshot"))
        if not screenshot_image(screenshot):
            issues.append("缺格式与扩展名相符的实际截图 PNG/JPEG")
        if not evidence(page.get("visualEvidence")):
            issues.append("缺逐页视觉核对记录")
        interactions = page.get("interactionEvidence", [])
        if not interactions or not all(evidence(item) for item in interactions):
            issues.append("缺交互验证记录")
        if page.get("sourceDigest") != source_hash or page.get("designDigest") != design_hash:
            issues.append("证据未绑定当前源码与设计版本")
        if issues:
            problems.append(page["id"] + ": " + "、".join(issues))
        else:
            passed += 1
    if acceptance.get("overall") != "passed":
        problems.append("整体验收尚未通过")
    print(f"UI 验收：{passed}/{len(expected)} 项具备完整且适用于当前版本的证据")
    for problem in problems:
        print("- " + problem)
    if problems and not args.report:
        print("发布门禁未通过；请完成实际客户端逐页验收。", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
