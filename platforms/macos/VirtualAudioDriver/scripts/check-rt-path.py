#!/usr/bin/env python3
"""Static realtime-path guard for the experimental multichannel driver.

This is not a proof, but it catches accidental allocation, locks, logging,
file/network calls, CF object work, or control-plane diagnostics in the
callbacks that run on the HAL IO thread.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src" / "FlowVirtualAudioMultichannel.c"
RT_FUNCTIONS = ("ZeroTime", "WillIO", "BeginIO", "DoIO")
FORBIDDEN = (
    "malloc(",
    "calloc(",
    "realloc(",
    "free(",
    "pthread_mutex_lock",
    "pthread_mutex_trylock",
    "os_log",
    "CFCreate",
    "CFRelease",
    "CFRetain",
    "CFEqual",
    "fopen",
    "socket(",
    "printf",
    "NSLog",
    "PropertyReadFailure",
    "Notify(",
    "memcpy(",
)


def strip_comments_and_literals(text: str) -> str:
    out = []
    i = 0
    n = len(text)
    while i < n:
        if text.startswith("//", i):
            end = text.find("\n", i)
            if end < 0:
                break
            out.append("\n")
            i = end + 1
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            if end < 0:
                break
            out.append("\n" * text.count("\n", i, end + 2))
            i = end + 2
        elif text[i] == '"':
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\":
                    i += 1
                i += 1
            i += 1
            out.append('""')
        elif text[i] == "'":
            i += 1
            while i < n and text[i] != "'":
                if text[i] == "\\":
                    i += 1
                i += 1
            i += 1
            out.append("''")
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def function_body(text: str, name: str) -> str:
    match = re.search(r"\b" + re.escape(name) + r"\s*\([^;{}]*\)\s*\{", text)
    if not match:
        raise SystemExit(f"FAIL: cannot locate {name} definition")
    start = match.end() - 1
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start + 1 : i]
    raise SystemExit(f"FAIL: unbalanced braces in {name}")


def main() -> int:
    if not SOURCE.exists():
        raise SystemExit(f"FAIL: missing {SOURCE}")
    stripped = strip_comments_and_literals(SOURCE.read_text(encoding="utf-8"))
    for name in RT_FUNCTIONS:
        body = function_body(stripped, name)
        for token in FORBIDDEN:
            if token in body:
                raise SystemExit(f"FAIL: {name} contains forbidden realtime token {token!r}")
    diagnostics = function_body(stripped, "PropertyReadFailure")
    if "os_log" not in diagnostics:
        raise SystemExit("FAIL: PropertyReadFailure no longer uses the bounded control log")
    print("PASS realtime path: no allocation/lock/log/file/network/CF work in "
          "ZeroTime/WillIO/BeginIO/DoIO")
    return 0


if __name__ == "__main__":
    sys.exit(main())
