#!/usr/bin/env python3
"""Compare captured real-model request bodies at raw and model-visible layers."""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Iterable, List, Sequence, Tuple


def stable_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def text_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def request_body_paths(capture_dir: Path) -> List[Path]:
    candidates = sorted((capture_dir / "requests").glob("*.body.json"))
    if candidates:
        return candidates
    return sorted(capture_dir.glob("**/*.body.json"))


def content_text(content: Any) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: List[str] = []
        for part in content:
            if isinstance(part, str):
                parts.append(part)
            elif isinstance(part, dict):
                if isinstance(part.get("text"), str):
                    parts.append(part["text"])
                elif isinstance(part.get("content"), str):
                    parts.append(part["content"])
                elif isinstance(part.get("input_text"), str):
                    parts.append(part["input_text"])
                elif isinstance(part.get("output_text"), str):
                    parts.append(part["output_text"])
                else:
                    parts.append(stable_json(part))
            else:
                parts.append(stable_json(part))
        return "\n".join(parts)
    return stable_json(content)


def normalize_arguments(arguments: Any) -> Any:
    if isinstance(arguments, str):
        try:
            return json.loads(arguments)
        except Exception:
            return arguments
    return arguments


@dataclass
class IdNormalizer:
    prefix: str
    values: Dict[str, str] = field(default_factory=dict)

    def normalize(self, value: Any) -> str | None:
        if value is None:
            return None
        raw = str(value)
        if not raw:
            return None
        if raw not in self.values:
            self.values[raw] = f"{self.prefix}_{len(self.values) + 1:03d}"
        return self.values[raw]


def visible_item(item: Any, call_ids: IdNormalizer, item_ids: IdNormalizer) -> Dict[str, Any]:
    if not isinstance(item, dict):
        text = content_text(item)
        return {
            "type": "literal",
            "text": text,
            "text_sha256": text_hash(text),
            "text_bytes": len(text.encode("utf-8")),
        }

    item_type = item.get("type") or item.get("kind") or "message"
    result: Dict[str, Any] = {"type": item_type}
    if item.get("id") is not None:
        result["id"] = item_ids.normalize(item.get("id"))

    if item_type == "function_call":
        result["name"] = item.get("name")
        result["call_id"] = call_ids.normalize(item.get("call_id"))
        result["arguments"] = normalize_arguments(item.get("arguments"))
        return result

    if item_type == "function_call_output":
        output = content_text(item.get("output"))
        result["call_id"] = call_ids.normalize(item.get("call_id"))
        result["output"] = output
        result["output_sha256"] = text_hash(output)
        result["output_bytes"] = len(output.encode("utf-8"))
        return result

    if "role" in item:
        result["role"] = item.get("role")
    if "name" in item:
        result["name"] = item.get("name")

    text = content_text(item.get("content"))
    if not text and isinstance(item.get("text"), str):
        text = item["text"]
    if not text and isinstance(item.get("summary"), list):
        text = content_text(item["summary"])
    if text:
        result["text"] = text
        result["text_sha256"] = text_hash(text)
        result["text_bytes"] = len(text.encode("utf-8"))

    known = {
        "arguments",
        "call_id",
        "content",
        "id",
        "kind",
        "name",
        "output",
        "role",
        "status",
        "summary",
        "text",
        "type",
    }
    extra = sorted(k for k in item.keys() if k not in known)
    if extra:
        result["extra_keys"] = extra
    if "status" in item:
        result["status"] = item.get("status")
    return result


def tool_names(body: Dict[str, Any]) -> List[str]:
    names: List[str] = []
    for tool in body.get("tools") or []:
        if isinstance(tool, dict):
            name = tool.get("name")
            if isinstance(name, str):
                names.append(name)
    return names


def normalize_requests(paths: Sequence[Path], label: str) -> List[Dict[str, Any]]:
    call_ids = IdNormalizer("call")
    item_ids = IdNormalizer("item")
    normalized: List[Dict[str, Any]] = []
    for index, path in enumerate(paths, start=1):
        body = read_json(path)
        if not isinstance(body, dict):
            body = {"_non_object_body": body}
        raw = stable_json(body)
        input_items = body.get("input")
        if not isinstance(input_items, list):
            input_items = []
        visible_sequence = [visible_item(item, call_ids, item_ids) for item in input_items]
        normalized.append(
            {
                "index": index,
                "label": label,
                "path": str(path),
                "raw_sha256": text_hash(raw),
                "raw_bytes": len(raw.encode("utf-8")),
                "top_level_keys": sorted(body.keys()),
                "model": body.get("model"),
                "stream": body.get("stream"),
                "tool_names": tool_names(body),
                "input_count": len(input_items),
                "visible_sequence": visible_sequence,
            }
        )
    return normalized


def sequence_lines(requests: Sequence[Dict[str, Any]]) -> List[str]:
    lines: List[str] = []
    for request in requests:
        lines.append(
            f"request {request['index']}: model={request.get('model')} "
            f"input_count={request.get('input_count')} tools={','.join(request.get('tool_names') or [])}"
        )
        for position, item in enumerate(request.get("visible_sequence") or [], start=1):
            compact = dict(item)
            for key in ("text", "output"):
                if key in compact:
                    text = compact[key]
                    compact[key] = {
                        "bytes": len(text.encode("utf-8")),
                        "sha256": text_hash(text),
                        "preview": text[:160],
                    }
            lines.append(f"  {position:03d} {stable_json(compact)}")
    return lines


def field_summary(requests: Sequence[Dict[str, Any]]) -> List[Dict[str, Any]]:
    return [
        {
            "index": req["index"],
            "path": req["path"],
            "top_level_keys": req["top_level_keys"],
            "model": req.get("model"),
            "stream": req.get("stream"),
            "tool_names": req.get("tool_names"),
            "input_count": req.get("input_count"),
            "raw_sha256": req.get("raw_sha256"),
            "raw_bytes": req.get("raw_bytes"),
        }
        for req in requests
    ]


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def make_report(
    msp: Sequence[Dict[str, Any]],
    codex: Sequence[Dict[str, Any]],
    diff_lines: Sequence[str],
    semantic_match: bool,
) -> str:
    lines: List[str] = []
    lines.append("# Real Model Request Parity")
    lines.append("")
    lines.append(f"- MSP requests: {len(msp)}")
    lines.append(f"- Codex requests: {len(codex)}")
    lines.append(f"- Model-visible sequence match: {'yes' if semantic_match else 'no'}")
    lines.append("")
    lines.append("## Field Summary")
    lines.append("")
    for label, requests in (("MSP", msp), ("Codex", codex)):
        lines.append(f"### {label}")
        if not requests:
            lines.append("")
            lines.append("_No captured requests._")
            lines.append("")
            continue
        for req in requests:
            lines.append(
                f"- request {req['index']}: input={req.get('input_count')} "
                f"model={req.get('model')} stream={req.get('stream')} "
                f"tools={', '.join(req.get('tool_names') or []) or '(none)'} "
                f"raw={req.get('raw_sha256')}"
            )
        lines.append("")
    lines.append("## Model-Visible Sequence Diff")
    lines.append("")
    if diff_lines:
        lines.append("```diff")
        lines.extend(diff_lines)
        lines.append("```")
    else:
        lines.append("_No sequence diff._")
    lines.append("")
    lines.append("Raw complete request bodies remain in each capture directory under `requests/*.body.json`.")
    return "\n".join(lines) + "\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--msp-dir", type=Path, required=True)
    parser.add_argument("--codex-dir", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--fail-on-diff", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)

    msp_paths = request_body_paths(args.msp_dir)
    codex_paths = request_body_paths(args.codex_dir)
    msp = normalize_requests(msp_paths, "msp")
    codex = normalize_requests(codex_paths, "codex")

    msp_lines = sequence_lines(msp)
    codex_lines = sequence_lines(codex)
    diff = list(
        difflib.unified_diff(
            msp_lines,
            codex_lines,
            fromfile="msp.model-visible",
            tofile="codex.model-visible",
            lineterm="",
        )
    )
    semantic_match = len(diff) == 0

    write_json(args.out_dir / "normalized-msp.json", msp)
    write_json(args.out_dir / "normalized-codex.json", codex)
    write_json(args.out_dir / "field-summary.json", {"msp": field_summary(msp), "codex": field_summary(codex)})
    (args.out_dir / "normalized-diff.md").write_text(
        make_report(msp, codex, diff, semantic_match),
        encoding="utf-8",
    )

    print(f"msp_requests={len(msp)}")
    print(f"codex_requests={len(codex)}")
    print(f"model_visible_sequence_match={'yes' if semantic_match else 'no'}")
    print(f"report={args.out_dir / 'normalized-diff.md'}")
    if args.fail_on_diff and not semantic_match:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
