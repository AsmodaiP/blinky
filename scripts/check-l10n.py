#!/usr/bin/env python3
"""Report UI strings in Sources/ that have no entry in a translation table.

Usage: scripts/check-l10n.py [lang]   (default: ru)
SwiftUI interpolations become %lld / %@ — a key passes if either variant exists.
"""
import itertools, pathlib, re, sys

root = pathlib.Path(__file__).resolve().parent.parent
lang = sys.argv[1] if len(sys.argv) > 1 else "ru"
table = (root / f"Resources/{lang}.lproj/Localizable.strings").read_text()
keys = set(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=', table, re.M))

UI = r'(?:Text|Button|Toggle|Stepper|Label|Section|Picker|LabeledContent|TextField|Menu|DatePicker|ModuleToggle|soundPicker|L|\.value|title:|prompt: Text|kind:)\s*\(?'
lit = re.compile(r'"((?:[^"\\]|\\.)*)"')
skip = re.compile(r'^[\s\W\d]*$|^[a-z]+\.[a-zA-Z.]+|^[a-z]+$')   # symbols, bundle IDs, tags

missing = set()
for f in sorted((root / "Sources").rglob("*.swift")):
    if f.name == "Debug.swift":
        continue
    for line in f.read_text().splitlines():
        code = line.split("//")[0] if not line.strip().startswith("//") else ""
        if not re.search(UI, code) and "?" not in code:
            continue
        for m in lit.finditer(code):
            s = m.group(1)
            if not re.search(r"[A-Za-z]{2}", s) or skip.match(s) or "\\(" in s and not re.search(r"[A-Za-z]{2}", re.sub(r"\\\([^)]*\)+", "", s)):
                continue
            if s in ("center", "edge", "full", "gentle", "gradient", "wallpaper", "image", "fgfs", "fg", "open", "Glass"):
                continue
            parts = re.split(r"\\\((?:[^()]|\([^()]*\))*\)", s)
            n = len(parts) - 1
            variants = {"".join(itertools.chain.from_iterable(zip(parts, list(c) + [""])))
                        for c in itertools.product(["%lld", "%@"], repeat=n)} if n else {s}
            if not variants & keys:
                missing.add(f"{f.name}: {s}")
print("\n".join(sorted(missing)) or "all UI strings are translated")
