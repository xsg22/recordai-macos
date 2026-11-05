"""Versioned analysis contract and offline, content-directed HTML rendering. Stdlib only."""
from __future__ import annotations

import base64
from datetime import datetime, timezone
import hashlib
from html import escape
import json
import math
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent


def obj(properties, required=None):
    return {"type": "object", "properties": properties, "required": required or list(properties), "additionalProperties": False}


def arr(items, minimum=0, maximum=1000):
    return {"type": "array", "items": items, "minItems": minimum, "maxItems": maximum}


TEXT = {"type": "string", "minLength": 1, "maxLength": 8000}
SHORT = {"type": "string", "minLength": 1, "maxLength": 160}
IDENTIFIER = {"type": "string", "pattern": r"^[a-zA-Z0-9_-]{1,100}$"}
REFS = arr(IDENTIFIER, 1, 1000)
NULLABLE = {"type": ["string", "null"], "minLength": 1, "maxLength": 300}
CLAIM = obj({"text": TEXT, "sourceIds": REFS, "detail": TEXT}, ["text", "sourceIds"])
ACTION = obj({"id": IDENTIFIER, "text": TEXT, "owner": NULLABLE, "dueText": NULLABLE, "sourceIds": REFS, "detail": TEXT}, ["id", "text", "owner", "dueText", "sourceIds"])
SECTION = obj({"label": SHORT, "text": TEXT, "sourceIds": REFS})
QUOTE = obj({"text": TEXT, "attribution": NULLABLE, "sourceIds": REFS})
ROW = obj({"label": SHORT, "values": arr(TEXT, 2, 12), "sourceIds": REFS})
BLOCK_ITEMS = {"key_points": CLAIM, "decisions": CLAIM, "questions": CLAIM,
               "actions": ACTION, "topics": SECTION, "concepts": SECTION,
               "timeline": SECTION, "quotes": QUOTE, "narrative": CLAIM}


def contract():
    blocks = []
    for kind, item in BLOCK_ITEMS.items():
        blocks.append(obj({"id": IDENTIFIER, "type": {"const": kind}, "title": SHORT,
                           "emphasis": {"enum": ["primary", "secondary"]}, "items": arr(item, 1, 100)},
                          ["id", "type", "title", "items"]))
    blocks.append(obj({"id": IDENTIFIER, "type": {"const": "comparison"}, "title": SHORT,
                       "emphasis": {"enum": ["primary", "secondary"]},
                       "columns": arr(SHORT, 2, 12), "rows": arr(ROW, 1, 100)},
                      ["id", "type", "title", "columns", "rows"]))
    return {"$schema": "https://json-schema.org/draft/2020-12/schema",
            "$id": "urn:talktuck:analysis-report:1", "title": "TalkTuck adaptive analysis report", **obj({
        "schemaVersion": {"const": 1}, "reportId": IDENTIFIER, "title": SHORT, "subtitle": SHORT,
        "overview": CLAIM, "notice": TEXT,
        "recording": obj({"id": SHORT, "title": SHORT, "revision": {"type": "integer", "minimum": 0},
                          "contentDigest": {"type": "string", "pattern": "^[a-f0-9]{64}$"},
                          "createdAt": SHORT, "durationSeconds": {"type": "number", "minimum": 0}}),
        "generation": obj({"provider": SHORT, "method": SHORT, "generatedAt": SHORT}),
        "coverage": obj({"status": {"enum": ["complete", "partial"]}, "includedSourceIds": REFS,
                         "omittedSourceIds": arr(IDENTIFIER), "note": TEXT}),
        "sources": arr(obj({"id": IDENTIFIER, "paragraphId": SHORT, "audioPart": {"type": "integer", "minimum": 1},
                            "startSeconds": {"type": ["number", "null"], "minimum": 0},
                            "endSeconds": {"type": ["number", "null"], "minimum": 0},
                            "text": {"type": "string", "minLength": 1, "maxLength": 1000000}, "speakerLabels": arr(SHORT, 0, 20)}), 1, 100000),
        "blocks": arr({"oneOf": blocks}, 1, 100),
        "warnings": arr(obj({"text": TEXT, "sourceIds": REFS}), 0, 100)
    }, ["schemaVersion", "reportId", "title", "subtitle", "overview", "recording", "generation", "coverage", "sources", "blocks", "warnings"])}


def draft_contract():
    schema = contract()
    protected = {"schemaVersion", "recording", "sources", "generation"}
    schema["properties"] = {key: value for key, value in schema["properties"].items() if key not in protected}
    schema["required"] = [key for key in schema["required"] if key not in protected]
    schema["$id"] = "urn:talktuck:analysis-draft:1"
    schema["title"] = "TalkTuck analyst draft; provenance is attached by the host"
    return schema


class InvalidReport(ValueError):
    pass


def check(value, schema, path="report"):
    """Validate the small JSON Schema vocabulary emitted by contract(), without dependencies."""
    if "oneOf" in schema:
        accepted = 0
        for branch in schema["oneOf"]:
            try:
                check(value, branch, path)
                accepted += 1
            except InvalidReport:
                pass
        if accepted != 1:
            raise InvalidReport(f"{path}: unsupported or malformed content block")
        return
    types = schema.get("type")
    allowed = types if isinstance(types, list) else [types] if types else []
    actual = "null" if value is None else "boolean" if isinstance(value, bool) else "string" if isinstance(value, str) else "object" if isinstance(value, dict) else "array" if isinstance(value, list) else "integer" if isinstance(value, int) else "number" if isinstance(value, float) else "invalid"
    if allowed and actual not in allowed and not (actual == "integer" and "number" in allowed):
        raise InvalidReport(f"{path}: expected {allowed}, got {actual}")
    if "const" in schema and (type(value) is not type(schema["const"]) or value != schema["const"]):
        raise InvalidReport(f"{path}: incorrect constant")
    if "enum" in schema and value not in schema["enum"]:
        raise InvalidReport(f"{path}: unsupported value")
    if isinstance(value, str):
        if not schema.get("minLength", 0) <= len(value) <= schema.get("maxLength", math.inf):
            raise InvalidReport(f"{path}: invalid string length")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            raise InvalidReport(f"{path}: invalid identifier or digest")
    elif actual in ("integer", "number"):
        if not math.isfinite(value) or value < schema.get("minimum", -math.inf):
            raise InvalidReport(f"{path}: invalid number")
    elif isinstance(value, dict):
        if any(k not in value for k in schema.get("required", [])):
            raise InvalidReport(f"{path}: missing required field")
        props = schema.get("properties", {})
        if schema.get("additionalProperties") is False and set(value) - set(props):
            raise InvalidReport(f"{path}: unknown fields {sorted(set(value) - set(props))}")
        for k, v in value.items():
            if k in props:
                check(v, props[k], f"{path}.{k}")
    elif isinstance(value, list):
        if not schema.get("minItems", 0) <= len(value) <= schema.get("maxItems", math.inf):
            raise InvalidReport(f"{path}: invalid item count")
        for i, v in enumerate(value):
            check(v, schema.get("items", {}), f"{path}[{i}]")


def snapshot_sources(snapshot):
    if snapshot.get("transcriptionReady") is not True or not snapshot.get("finalText", "").strip():
        raise InvalidReport("Saved final transcription is required; live drafts are not accepted")
    paragraphs = snapshot.get("paragraphs", [])
    if not paragraphs:
        raise InvalidReport("This first report contract requires paragraph IDs for verifiable citations")
    sources = []
    for i, p in enumerate(paragraphs):
        sources.append({"id": f"s{i + 1:04d}", "paragraphId": p["id"], "audioPart": p.get("audioPart", 1),
                        "startSeconds": p.get("start"), "endSeconds": p.get("end"),
                        "text": p["text"], "speakerLabels": p.get("speakers", [])})
    return sources


def validate(report, snapshot=None):
    check(report, contract())
    ids = [s["id"] for s in report["sources"]]
    if len(set(ids)) != len(ids) or len({s["paragraphId"] for s in report["sources"]}) != len(ids):
        raise InvalidReport("Duplicate source or paragraph IDs")
    allowed = set(ids)
    coverage = report["coverage"]
    included, omitted = set(coverage["includedSourceIds"]), set(coverage["omittedSourceIds"])
    if len(included) != len(coverage["includedSourceIds"]) or len(omitted) != len(coverage["omittedSourceIds"]) or included & omitted or included | omitted != allowed:
        raise InvalidReport("Coverage must partition all source IDs exactly once")
    if coverage["status"] == "complete" and omitted or coverage["status"] == "partial" and not omitted:
        raise InvalidReport("Coverage status does not match included/omitted sources")
    if len({b["id"] for b in report["blocks"]}) != len(report["blocks"]):
        raise InvalidReport("Duplicate block IDs")
    action_ids = []
    for source in report["sources"]:
        a, b = source["startSeconds"], source["endSeconds"]
        if (a is None) != (b is None) or a is not None and (b < a or b > report["recording"]["durationSeconds"] + 1):
            raise InvalidReport("Invalid source time interval")

    def refs(value):
        if isinstance(value, dict):
            if "sourceIds" in value:
                actual = value["sourceIds"]
                if len(set(actual)) != len(actual) or not set(actual) <= included:
                    raise InvalidReport("Claim cites unknown, omitted or duplicate sources")
            for child in value.values():
                refs(child)
        elif isinstance(value, list):
            for child in value:
                refs(child)
    refs(report)
    for block in report["blocks"]:
        if block["type"] == "comparison" and any(len(row["values"]) != len(block["columns"]) for row in block["rows"]):
            raise InvalidReport("Comparison row width does not match columns")
        if block["type"] == "actions":
            action_ids.extend(i["id"] for i in block["items"])
        if block["type"] == "quotes":
            for quote in block["items"]:
                candidates = [s["text"] for s in report["sources"] if s["id"] in quote["sourceIds"]]
                if quote["text"] not in "".join(candidates):
                    raise InvalidReport("A quotation must occur verbatim in its cited sources")
    if len(set(action_ids)) != len(action_ids):
        raise InvalidReport("Duplicate action IDs")
    for key in ["generation", "recording"]:
        stamp = report[key]["generatedAt" if key == "generation" else "createdAt"]
        try:
            if datetime.fromisoformat(stamp.replace("Z", "+00:00")).tzinfo is None:
                raise ValueError()
        except ValueError as exc:
            raise InvalidReport("Timestamps must be ISO 8601 with timezone") from exc
    if snapshot is not None:
        actual = report["recording"]
        for name, snapshot_name in [("id", "id"), ("revision", "revision"), ("contentDigest", "contentDigest"), ("title", "title"), ("createdAt", "createdAt"), ("durationSeconds", "duration")]:
            if actual[name] != snapshot[snapshot_name]:
                raise InvalidReport(f"Transcript changed or report refers to a different recording: {name}")
        if report["sources"] != snapshot_sources(snapshot):
            raise InvalidReport("Sources differ from the actual saved transcript")
    return report


def clock(seconds):
    if seconds is None:
        return "原文"
    n = int(seconds)
    return f"{n // 3600}:{n // 60 % 60:02}:{n % 60:02}" if n >= 3600 else f"{n // 60:02}:{n % 60:02}"


def layout(report):
    """Composition is derived from present semantic blocks; there are no empty template slots."""
    # The analyst's primary block and ordering express the dominant content, even in mixed reports.
    primary = next((b for b in report["blocks"] if b.get("emphasis") == "primary"), report["blocks"][0])
    return {"comparison": ("decision", "方案对照"), "actions": ("action", "行动简报"),
            "concepts": ("knowledge", "知识笔记"), "quotes": ("interview", "观点摘录"),
            "timeline": ("chronicle", "内容脉络")}.get(primary["type"], ("reading", "阅读摘要"))


def render(report, audio_name=None):
    validate(report)
    if audio_name and not re.fullmatch(r"audio\.(m4a|wav|mp3|caf)", audio_name):
        raise InvalidReport("Audio must be an optional relative bundle asset")
    h = lambda v: escape(str(v), quote=True)
    sources = {s["id"]: s for s in report["sources"]}

    def citations(ids):
        groups = {}
        for i in sorted(ids, key=lambda key: (sources[key]["audioPart"], sources[key]["startSeconds"] if sources[key]["startSeconds"] is not None else math.inf)):
            key = (sources[i]["audioPart"], clock(sources[i]["startSeconds"]))
            groups.setdefault(key, []).append(i)
        buttons = []
        for (_, label), grouped in groups.items():
            suffix = f" · {len(grouped)} 段" if len(grouped) > 1 else ""
            buttons.append(f'<button class="citation" data-source="{h(",".join(grouped))}" aria-label="查看 {label}{suffix} 的原文">↗ {label}{suffix}</button>')
        visible = "".join(buttons[:3]) if len(buttons) > 4 else "".join(buttons)
        if len(buttons) > 4:
            visible += f'<details class="citation-more"><summary>另 {len(buttons) - 3} 处依据</summary><div class="citation-extra">' + "".join(buttons[3:]) + '</div></details>'
        return '<div class="citations" aria-label="原文依据">' + visible + "</div>"

    fragments = []
    for index, block in enumerate(report["blocks"]):
        kind = block["type"]
        emphasis = block.get("emphasis", "primary" if kind in ("actions", "comparison", "concepts", "timeline") else "secondary")
        body = ""
        for n, item in enumerate(block.get("items", [])):
            evidence = citations(item["sourceIds"])
            if kind == "actions":
                due = item["dueText"] or "期限待明确"
                owner = item["owner"] or "负责人待明确"
                detail = f'<p class="item-detail">{h(item["detail"])}</p>' if item.get("detail") else ""
                body += f'<article class="action-item"><div class="action-top"><span class="item-index">{n+1:02}</span><span class="due {"undated" if not item["dueText"] else ""}">{h(due)}</span></div><h3>{h(item["text"])}</h3>{detail}<div class="action-bottom"><span class="owner"><span class="avatar">{h(owner[0])}</span>{h(owner)}</span><label class="follow"><input type="checkbox" data-action="{h(item["id"])}"><span>标记完成</span></label></div>{evidence}</article>'
            elif kind == "quotes":
                body += f'<figure class="quote"><blockquote>{h(item["text"])}</blockquote><figcaption>{h(item["attribution"] or "原文未明确署名")}</figcaption>{evidence}</figure>'
            elif kind in ("concepts", "topics", "timeline"):
                body += f'<article class="topic"><span class="topic-marker">{n+1:02}</span><div><h3>{h(item["label"])}</h3><p>{h(item["text"])}</p>{evidence}</div></article>'
            else:
                detail = f'<p class="item-detail">{h(item["detail"])}</p>' if item.get("detail") else ""
                body += f'<article class="point"><span class="point-dot"></span><div><p>{h(item["text"])}</p>{detail}{evidence}</div></article>'
        if kind == "comparison":
            head = "".join(f'<th scope="col">{h(c)}</th>' for c in block["columns"])
            rows = "".join(f'<tr><th scope="row">{h(row["label"])}{citations(row["sourceIds"])}</th>' + "".join(f'<td>{h(v)}</td>' for v in row["values"]) + '</tr>' for row in block["rows"])
            body = f'<div class="table-scroll" role="region" aria-label="{h(block["title"])}" tabindex="0"><table><thead><tr><th scope="col">维度</th>{head}</tr></thead><tbody>{rows}</tbody></table></div>'
        fragments.append(f'<section id="block-{h(block["id"])}" class="report-block {kind} {emphasis}"><div class="section-heading"><span class="section-number">{index+1:02}</span><h2>{h(block["title"])}</h2></div><div class="block-body">{body}</div></section>')
    mode, mode_title = layout(report)
    composition = " composition-action-triad" if [b["type"] for b in report["blocks"]] == ["actions", "key_points", "questions"] else ""
    actions = [a for b in report["blocks"] if b["type"] == "actions" for a in b["items"]]
    dated = next((a for a in actions if a["dueText"]), None)
    if dated:
        spotlight = f'<span class="spotlight-label">本次明确的时间点</span><strong>{h(dated["dueText"])}</strong><p>{h(dated["text"])}</p><span class="spotlight-foot">其余期限不作推断</span>'
    else:
        spotlight = f'<span class="spotlight-label">这份内容的阅读方式</span><strong class="reading-label">{mode_title}</strong><p>先看核心信息，再按来源展开细节。</p><span class="spotlight-foot">{len(report["blocks"])} 个内容板块 · 原文可追溯</span>'
    warnings = "".join(f'<div class="warning"><span aria-hidden="true">!</span><div><p>{h(w["text"])}</p>{citations(w["sourceIds"])}</div></div>' for w in report["warnings"])
    source_html = "".join(f'<article id="source-{h(s["id"])}" class="source-row"><button class="source-time" data-play="{h(s["id"])}" aria-label="定位 {clock(s["startSeconds"])} 的录音">{clock(s["startSeconds"])}</button><div><span class="speaker">{h(" / ".join(s["speakerLabels"]) or "发言人未标注")}</span><p>{h(s["text"])}</p></div></article>' for s in report["sources"])
    audio = f'<audio id="recording-audio" controls preload="metadata" src="{h(audio_name)}"></audio><p id="audio-status" role="status">点击原文时间可定位录音；点击播放后才会发声。</p>' if audio_name else '<p id="audio-status">此报告未附原音；引用仍可展开查看。</p>'
    c = report["coverage"]
    coverage_text = "全文已纳入分析" if c["status"] == "complete" else f'部分覆盖 · {len(c["omittedSourceIds"])} 个片段未纳入'
    record = report["recording"]
    raw_json = json.dumps(report, ensure_ascii=False, indent=2)
    embedded = json.dumps({"report": report, "audioAvailable": bool(audio_name)}, ensure_ascii=False).replace("<", "\\u003c").replace("&", "\\u0026")
    css, js = (HERE / "report.css").read_text(), (HERE / "report.js").read_text()
    digest = lambda text: base64.b64encode(hashlib.sha256(text.encode()).digest()).decode()
    csp = f"default-src 'none'; style-src 'sha256-{digest(css)}'; script-src 'sha256-{digest(js)}'; media-src 'self' blob:; img-src data:; connect-src 'none'; base-uri 'none'; form-action 'none'"
    return f'''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="{h(csp)}"><meta name="color-scheme" content="light"><title>{h(report['title'])} · TalkTuck</title><style>{css}</style></head>
<body class="layout-{mode}{composition}"><a class="skip-link" href="#main">跳到报告正文</a><div class="shell"><header class="topbar"><a class="brand" href="#main"><span class="brand-icon" aria-hidden="true">▥</span>TalkTuck<span class="brand-sub">内容洞察</span></a><div class="top-actions"><a href="report.json" download>↓ JSON</a><button id="print-report">导出 / 打印</button></div></header>
<main id="main"><div class="report-meta"><span class="report-type">{mode_title}</span><span>{h(report['subtitle'])}</span><span class="dot">·</span><time datetime="{h(record['createdAt'])}" class="recording-date">{h(record['createdAt'])}</time></div>
<div class="hero"><div class="hero-copy"><h1>{h(report['title'])}</h1><p class="overview">{h(report['overview']['text'])}</p>{citations(report['overview']['sourceIds'])}<div class="trust-line"><span class="trust-dot"></span>{coverage_text}<span>·</span>原音 {clock(record['durationSeconds'])}{f'<span>·</span>{len(actions)} 项待跟进' if actions else ''}</div></div><aside class="spotlight">{spotlight}</aside></div>
{f'<div class="sample-notice">{h(report["notice"])}</div>' if report.get('notice') else ''}
<div class="blocks">{''.join(fragments)}</div>{f'<aside class="warnings" aria-label="核对提示">{warnings}</aside>' if warnings else ''}
<section class="sources-panel"><details id="sources"><summary><span>回到原文</span><span class="summary-hint">{len(sources)} 个片段 · 查看依据与录音</span></summary><div class="sources-body">{audio}<div class="source-list">{source_html}</div></div></details></section>
<details class="json-panel"><summary>查看结构化 JSON</summary><pre>{h(raw_json)}</pre></details>
<footer><span>依据「{h(record['title'])}」整理 · {h(report['generation']['provider'])}</span><span>AI 分析请结合原文核对</span>{'<p id="local-state-note" role="status">勾选只记录在当前浏览器，不会改写分析 JSON。</p>' if actions else ''}<p>{h(c['note'])}</p></footer></main></div><script id="report-data" type="application/json">{embedded}</script><script>{js}</script></body></html>'''
