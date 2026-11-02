"""Report business contracts: provenance, full coverage, non-meeting layouts and safe export."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from html.parser import HTMLParser

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from Reports.report import InvalidReport, contract, layout, render, validate

spec = importlib.util.spec_from_file_location("analysis_cli", ROOT / "Scripts/analysis-report.py")
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)


class ReportContracts(unittest.TestCase):
    def setUp(self):
        self.report = json.loads((ROOT / "Docs/examples/adaptive-report/output/report.json").read_text())
        r = self.report["recording"]
        self.snapshot = {"id": r["id"], "title": r["title"], "createdAt": r["createdAt"], "duration": r["durationSeconds"],
                         "revision": r["revision"], "contentDigest": r["contentDigest"], "transcriptionReady": True,
                         "finalText": "\n".join(s["text"] for s in self.report["sources"]),
                         "paragraphs": [{"id": s["paragraphId"], "text": s["text"], "start": s["startSeconds"],
                                         "end": s["endSeconds"], "audioPart": s["audioPart"], "speakers": s["speakerLabels"]}
                                        for s in self.report["sources"]]}

    def test_actual_report_source_binding_and_unknown_deadline(self):
        validate(self.report, self.snapshot)
        self.assertIsNone(self.report["blocks"][0]["items"][1]["dueText"])
        self.assertEqual(layout(self.report)[0], "action")
        self.snapshot["revision"] += 1
        with self.assertRaisesRegex(InvalidReport, "revision"):
            validate(self.report, self.snapshot)
        self.snapshot["revision"] -= 1
        self.snapshot["paragraphs"][0]["text"] = "different transcript"
        with self.assertRaisesRegex(InvalidReport, "Sources differ"):
            validate(self.report, self.snapshot)

    def test_partial_cannot_claim_complete_or_cite_omitted_material(self):
        report = copy.deepcopy(self.report)
        report["coverage"]["includedSourceIds"].remove("s0006")
        report["coverage"]["omittedSourceIds"] = ["s0006"]
        with self.assertRaisesRegex(InvalidReport, "Coverage status"):
            validate(report)
        report["coverage"]["status"] = "partial"
        with self.assertRaisesRegex(InvalidReport, "omitted"):
            validate(report)
        report["sources"][0]["endSeconds"] = 200
        with self.assertRaises(InvalidReport):
            validate(report)

    def test_duplicate_and_invented_citations_rejected(self):
        for refs in [["s9999"], ["s0001", "s0001"]]:
            report = copy.deepcopy(self.report)
            report["overview"]["sourceIds"] = refs
            with self.assertRaises(InvalidReport):
                validate(report)
        self.report["blocks"][0]["items"][1]["id"] = self.report["blocks"][0]["items"][0]["id"]
        with self.assertRaisesRegex(InvalidReport, "action IDs"):
            validate(self.report)

    def test_empty_or_unknown_blocks_and_business_inference_fields_rejected(self):
        for block in [dict(self.report["blocks"][0], items=[]), dict(self.report["blocks"][0], type="arbitrary_html")]:
            report = dict(self.report, blocks=[block])
            with self.assertRaises(InvalidReport):
                validate(report)
        self.report["blocks"][0]["items"][0]["isActuallyCompleted"] = True
        with self.assertRaises(InvalidReport):
            validate(self.report)

    def test_lecture_and_comparison_choose_different_compositions(self):
        lecture = dict(self.report, blocks=[{"id": "concepts", "type": "concepts", "title": "概念整理", "items": [
            {"label": "离线转录", "text": "由片段提取的知识说明（仅测试布局）", "sourceIds": ["s0001"]}]}])
        html = render(lecture)
        self.assertEqual(layout(lecture)[0], "knowledge")
        self.assertNotIn('class="action-item"', html)
        self.assertNotIn("期限待明确", html)
        self.assertIn('class="topic"', html)
        lecture["blocks"][0]["emphasis"] = "primary"
        lecture["blocks"].append(copy.deepcopy(self.report["blocks"][0]))
        self.assertEqual(layout(lecture)[0], "knowledge", "A minor to-do section must not replace a lecture's knowledge layout")
        self.assertNotIn('composition-action-triad', render(lecture).split('<body', 1)[1].split('>', 1)[0])
        compare = dict(self.report, blocks=[{"id": "compare", "type": "comparison", "title": "测试对照", "columns": ["选项甲", "选项乙"],
                                          "rows": [{"label": "维度", "values": ["仅用于验证布局", "仅用于验证布局"], "sourceIds": ["s0001"]}]}])
        self.assertEqual(layout(compare)[0], "decision")
        self.assertIn('<table>', render(compare))
        compare["blocks"][0]["rows"][0]["values"].append("unmatched")
        with self.assertRaisesRegex(InvalidReport, "row width"):
            validate(compare)

    def test_quotes_are_verbatim_and_hostile_text_never_executes(self):
        report = dict(self.report, blocks=[{"id": "quote", "type": "quotes", "title": "引用", "items": [
            {"text": "不存在的引用", "attribution": None, "sourceIds": ["s0001"]}]}])
        with self.assertRaisesRegex(InvalidReport, "verbatim"):
            validate(report)
        report["blocks"][0]["items"][0]["text"] = self.report["sources"][0]["text"]
        render(report)
        attack = '</script><img src=x onerror="alert(1)">'
        self.report["overview"]["text"] = attack
        html = render(self.report)
        self.assertNotIn(attack, html)
        self.assertIn("&lt;/script&gt;", html)
        self.assertIn('Content-Security-Policy', html)
        with self.assertRaises(InvalidReport):
            render(self.report, "https://external.example/audio.m4a")

    def test_many_citations_remain_available_without_meeting_controls(self):
        report = copy.deepcopy(self.report)
        refs = [s["id"] for s in report["sources"]]
        report["overview"]["sourceIds"] = refs
        report["blocks"] = [{"id": "timeline", "type": "timeline", "title": "话题脉络", "items": [
            {"label": "日常交流", "text": "布局验证", "sourceIds": refs}]}]
        html = render(report)
        self.assertIn('class="citation-more"', html)
        self.assertNotIn('id="local-state-note"', html)
        class References(HTMLParser):
            def __init__(self):
                super().__init__()
                self.ids = set()
            def handle_starttag(self, tag, attrs):
                values = dict(attrs)
                if tag == "button" and "data-source" in values:
                    self.ids.update(values["data-source"].split(","))
        parser = References()
        parser.feed(html)
        self.assertEqual(parser.ids, set(refs), "Collapsing long references must not discard evidence")

    def test_long_paragraphs_are_exhaustively_split_without_losing_characters(self):
        self.snapshot["paragraphs"][0]["text"] = "知识片段。" * 5000
        prepared = cli.prepare(self.snapshot, 5000)
        parts = [p for chunk in prepared["chunks"] for p in chunk["parts"] if p["sourceId"] == "s0001"]
        self.assertGreater(len(parts), 1)
        self.assertEqual("".join(p["text"] for p in parts), self.snapshot["paragraphs"][0]["text"])
        self.assertTrue(all(p["endCharacter"] - p["startCharacter"] == len(p["text"]) for p in parts))
        self.assertTrue(all(sum(len(p["text"]) for p in c["parts"]) <= 5000 for c in prepared["chunks"]))
        self.snapshot["transcriptionReady"] = False
        with self.assertRaises(InvalidReport):
            cli.prepare(self.snapshot)

    def test_atomic_bundle_preserves_modified_files_and_schema_stays_current(self):
        self.assertEqual(json.loads((ROOT / "Reports/analysis-report.schema.json").read_text()), contract())
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "report"
            cli.package(self.report, output)
            self.assertEqual(json.loads((output / "report.json").read_text()), self.report)
            cli.package(self.report, output, replace=True)
            (output / "report.json").write_text("USER EDIT")
            with self.assertRaisesRegex(InvalidReport, "modified"):
                cli.package(self.report, output, replace=True)
            self.assertEqual((output / "report.json").read_text(), "USER EDIT")
            (output / "notes.txt").write_text("USER NOTES")
            with self.assertRaisesRegex(InvalidReport, "unrecognized"):
                cli.package(self.report, output, replace=True)
            self.assertEqual((output / "notes.txt").read_text(), "USER NOTES")


if __name__ == "__main__":
    unittest.main()
