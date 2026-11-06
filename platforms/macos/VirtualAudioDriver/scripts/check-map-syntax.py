#!/usr/bin/env python3
"""Optional local syntax check for the pure C mapping model.

The real build is on macOS.  This script lets a non-Mac reviewer catch C
syntax errors in FlowMultichannelMap.c/.h with pycparser when available.
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
HEADER = ROOT / "src" / "FlowMultichannelMap.h"
SOURCE = ROOT / "src" / "FlowMultichannelMap.c"


def strip_comments(text: str) -> str:
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
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def main() -> int:
    try:
        from pycparser import CParser
    except ImportError:
        print("SKIP map syntax check: pycparser is not installed")
        return 0

    header = HEADER.read_text(encoding="utf-8")
    source = SOURCE.read_text(encoding="utf-8")
    for text in (header, source):
        if "#if" in text or "#ifdef" in text or "#ifndef" in text:
            print("SKIP map syntax check: preprocessor conditionals present")
            return 0

    combined = strip_comments(header) + "\n" + strip_comments(source)
    combined = combined.replace("#pragma once", "")
    combined = "\n".join(
        line for line in combined.splitlines()
        if not line.strip().startswith("#")
    )
    combined = combined.replace("MC_MAX_CHANNELS", "16")
    prelude = """
    typedef unsigned char uint8_t;
    typedef signed int int32_t;
    typedef unsigned int uint32_t;
    typedef unsigned long size_t;
    typedef _Bool bool;
    void *memcpy(void *, const void *, size_t);
    void *memset(void *, int, size_t);
    """
    parser = CParser()
    try:
        parser.parse(prelude + "\n" + combined)
    except Exception as exc:  # pycparser raises ParseError
        print(f"FAIL map syntax: {exc}", file=sys.stderr)
        return 1
    print("PASS map syntax: FlowMultichannelMap.c/.h parse")
    return 0


if __name__ == "__main__":
    sys.exit(main())
