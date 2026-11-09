#!/usr/bin/env python3
"""Extract read-value latency evidence from a Chrome tracing JSON.

This tool is deliberately conservative. It does not hard-code a Chrome event
name because event names vary by Chrome/Chromium version. It searches the trace
for events whose category or name mentions audio/latency, then digs numeric
latency/delay/playout arguments out of the event arguments. It reports whether
any `hardware_latency_us` sample is actually present and, if so, its P95.

An empty result means "no latency evidence found", NOT "latency passed".

Usage:
    python3 analyze_latency_trace.py trace.json [-o latency_analysis.json] \
        [--version-file chrome_version.json]
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path

LATENCY_KEY_RE = re.compile(r"(?i)latency|delay|playout|hardware|buffer|frames|rate")
NAME_RE = re.compile(r"(?i)(auhal|latency|delay|playout|audiodevice|audiorenderer|audiooutput)")


def load_trace(path: Path):
    text = path.read_text(encoding="utf-8", errors="replace")
    data = json.loads(text)
    if isinstance(data, dict) and "traceEvents" in data:
        return data, data["traceEvents"]
    if isinstance(data, dict) and "events" in data:
        return data, data["events"]
    if isinstance(data, list):
        return {}, data
    raise SystemExit(f"unrecognized trace format: {path}")


def walk(value, prefix=""):
    """Yield (dotted_key, numeric_value) for every numeric leaf."""
    if isinstance(value, dict):
        for key, child in value.items():
            yield from walk(child, f"{prefix}.{key}" if prefix else str(key))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from walk(child, f"{prefix}[{index}]")
    elif isinstance(value, (int, float)) and not isinstance(value, bool):
        yield prefix, float(value)


def percentile(sorted_values, p):
    if not sorted_values:
        return None
    index = max(1, math.ceil(p / 100.0 * len(sorted_values)))
    return sorted_values[index - 1]


def summarize(path: Path, version_file: Path | None) -> dict:
    metadata, events = load_trace(path)
    matched = []
    metric_samples = []
    for event in events:
        if not isinstance(event, dict):
            continue
        cat = str(event.get("cat", ""))
        name = str(event.get("name", ""))
        if "audio" not in cat.lower() and not NAME_RE.search(name):
            continue
        row = {
            "name": name,
            "cat": cat,
            "ph": event.get("ph"),
            "ts": event.get("ts"),
            "pid": event.get("pid"),
            "tid": event.get("tid"),
            "args_keys": [],
        }
        for key, value in walk(event.get("args", {})):
            if LATENCY_KEY_RE.search(key):
                row["args_keys"].append(key)
                metric_samples.append({"event": name, "ts": event.get("ts"), "key": key, "value": value})
        matched.append(row)

    unique_names = sorted({e["name"] for e in matched})
    hardware = [s for s in metric_samples if s["key"].lower() == "hardware_latency_us"
                or s["key"].endswith(".hardware_latency_us")]
    hardware_sorted = sorted(s["value"] for s in hardware)
    playout = [s for s in metric_samples if "playout" in s["key"].lower()
               or "delay" in s["key"].lower() or "latency" in s["key"].lower()]
    playout_sorted = sorted(s["value"] for s in playout)

    chrome_version = None
    if version_file and Path(version_file).exists():
        chrome_version = json.loads(Path(version_file).read_text(encoding="utf-8"))

    summary = {
        "schema": "hpf-chrome-trace-analysis.v1",
        "trace": str(path),
        "total_events": len(events),
        "matched_events": len(matched),
        "unique_matched_names": unique_names,
        "latency_key_seen": sorted({s["key"] for s in metric_samples}),
        "hardware_latency_us": {
            "samples": len(hardware_sorted),
            "p50": percentile(hardware_sorted, 50),
            "p95_us": percentile(hardware_sorted, 95),
            "max": hardware_sorted[-1] if hardware_sorted else None,
            "values": hardware_sorted,
        },
        "general_latency_samples": {
            "samples": len(playout_sorted),
            "p95": percentile(playout_sorted, 95),
            "max": playout_sorted[-1] if playout_sorted else None,
        },
        "evidence_found": False,
        "chrome_version": chrome_version,
        "sample_events": matched[:200],
    }
    summary["evidence_found"] = len(hardware_sorted) > 0
    return summary


def main(argv):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("trace")
    p.add_argument("-o", "--output", default=None)
    p.add_argument("--version-file", default=None)
    args = p.parse_args(argv)

    summary = summarize(Path(args.trace), Path(args.version_file) if args.version_file else None)
    text = json.dumps(summary, indent=2, ensure_ascii=True)
    if args.output:
        Path(args.output).write_text(text, encoding="utf-8")
        print(f"wrote {args.output}")
    else:
        print(text)
    if not summary["evidence_found"]:
        print("NOTE: no hardware_latency_us samples present; proof is MISSING.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
