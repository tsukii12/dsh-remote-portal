#!/usr/bin/env python3
"""Lists Dart string literals that still contain Chinese (i18n leftovers).

Comments are skipped. A literal is kept on purpose when its line, or the
line above, carries `l10n:keep` (e.g. `// l10n:keep 引擎输出前缀`), or when it
sits between `// l10n:keep-begin` and `// l10n:keep-end`.

Usage:
  tool/l10n_scan.py [paths...]            # default: lib/
  tool/l10n_scan.py --count lib/ui        # per-file counts, biggest first
  tool/l10n_scan.py --dirs lib            # per-directory counts
  tool/l10n_scan.py --json out.json lib   # machine-readable
"""
from __future__ import annotations

import json
import os
import re
import sys
from collections import Counter

CJK = re.compile(r'[㐀-鿿豈-﫿　-〿！-｠]')
HAN = re.compile(r'[㐀-鿿]')
SKIP_FILE = re.compile(r'(\.g\.dart|/l10n/gen/|/l10n/.*\.dart)$')


def literals(src: str):
    """Yields (line, text) for each string literal (interpolations skipped)."""
    i, n, line = 0, len(src), 1
    # Stack of brace depths for `${ ... }` inside strings we are parsing.
    out = []

    def scan_string(i: int, line: int, raw: bool, quote: str):
        triple = src.startswith(quote * 3, i)
        q = quote * 3 if triple else quote
        i += len(q)
        start_line = line
        buf = []
        while i < n:
            c = src[i]
            if src.startswith(q, i):
                return i + len(q), line, start_line, ''.join(buf)
            if c == '\n':
                line += 1
                if not triple:
                    return i, line, start_line, ''.join(buf)
            if not raw and c == '\\' and i + 1 < n:
                buf.append(src[i:i + 2])
                if src[i + 1] == '\n':
                    line += 1
                i += 2
                continue
            if not raw and c == '$' and i + 1 < n and src[i + 1] == '{':
                # interpolation: scan code until matching brace
                i, line = scan_code(i + 2, line, stop_at_brace=True)
                buf.append('{}')
                continue
            buf.append(c)
            i += 1
        return i, line, start_line, ''.join(buf)

    def scan_code(i: int, line: int, stop_at_brace: bool):
        depth = 0
        while i < n:
            c = src[i]
            if c == '\n':
                line += 1
                i += 1
            elif src.startswith('//', i):
                j = src.find('\n', i)
                i = n if j < 0 else j
            elif src.startswith('/*', i):
                d, i = 1, i + 2
                while i < n and d:
                    if src.startswith('/*', i):
                        d, i = d + 1, i + 2
                    elif src.startswith('*/', i):
                        d, i = d - 1, i + 2
                    else:
                        if src[i] == '\n':
                            line += 1
                        i += 1
            elif c in '\'"':
                raw = i > 0 and src[i - 1] in 'rR' and (i < 2 or not (src[i - 2].isalnum() or src[i - 2] == '_'))
                i, line, sl, text = scan_string(i, line, raw, c)
                out.append((sl, text))
            elif c == '{':
                depth += 1
                i += 1
            elif c == '}':
                if stop_at_brace and depth == 0:
                    return i + 1, line
                depth -= 1
                i += 1
            else:
                i += 1
        return i, line

    scan_code(0, 1, False)
    return out


def scan_file(path: str):
    try:
        src = open(path, encoding='utf-8').read()
    except (OSError, UnicodeDecodeError):
        return []
    lines = src.split('\n')
    kept = set()
    inside = False
    for i, l in enumerate(lines, 1):
        if 'l10n:keep-begin' in l:
            inside = True
        if inside:
            kept.add(i)
        if 'l10n:keep-end' in l:
            inside = False
    hits = []
    for ln, text in literals(src):
        if not HAN.search(text):
            continue
        here = lines[ln - 1] if ln - 1 < len(lines) else ''
        above = lines[ln - 2] if ln - 2 >= 0 else ''
        if ln in kept or 'l10n:keep' in here or 'l10n:keep' in above:
            continue
        hits.append((ln, text))
    return hits


def dart_files(paths):
    for p in paths:
        if os.path.isfile(p):
            yield p
            continue
        for root, _, files in os.walk(p):
            for f in files:
                full = os.path.join(root, f)
                if f.endswith('.dart') and not SKIP_FILE.search(full.replace('\\', '/')):
                    yield full


def main(argv):
    mode, out_json, paths = 'list', None, []
    it = iter(argv)
    for a in it:
        if a == '--count':
            mode = 'count'
        elif a == '--dirs':
            mode = 'dirs'
        elif a == '--json':
            out_json = next(it)
        else:
            paths.append(a)
    paths = paths or ['lib']
    result = {f: scan_file(f) for f in sorted(dart_files(paths))}
    result = {f: h for f, h in result.items() if h}
    total = sum(len(h) for h in result.values())
    if out_json:
        with open(out_json, 'w', encoding='utf-8') as output:
            json.dump({f: [[ln, t] for ln, t in h] for f, h in result.items()}, output, ensure_ascii=False, indent=1)
    if mode == 'count':
        for f, h in sorted(result.items(), key=lambda kv: -len(kv[1])):
            print(f'{len(h):5d}  {f}')
    elif mode == 'dirs':
        c = Counter()
        for f, h in result.items():
            c[os.path.dirname(f)] += len(h)
        for d, k in c.most_common():
            print(f'{k:5d}  {d}')
    elif not out_json:
        for f, h in result.items():
            for ln, t in h:
                print(f'{f}:{ln}: {t}')
    print(f'# {total} literals in {len(result)} files', file=sys.stderr)


if __name__ == '__main__':
    # Match the other maintenance CLIs when redirected through legacy pipes.
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding='utf-8', errors=stream.errors)
    main(sys.argv[1:])
