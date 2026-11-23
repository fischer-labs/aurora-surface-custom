#!/usr/bin/env python3
"""Validate shared/grocery/taxonomy.json.

Normalizes every term exactly the way the apps do (see shared/README.md) and
fails if a normalized term maps to two different categories.
Usage: python3 shared/tools/taxonomy_check.py [--fix-dupes]
"""
import json, re, sys, unicodedata, pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
PATH = ROOT / "grocery" / "taxonomy.json"

def normalize(s: str) -> str:
    s = unicodedata.normalize("NFD", s.lower())
    s = "".join(c for c in s if unicodedata.category(c) != "Mn")
    s = s.replace("&", " and ").replace("'", "").replace("’", "")
    s = re.sub(r"[^a-z0-9%]+", " ", s)
    return " ".join(s.split())

def main():
    data = json.loads(PATH.read_text())
    keys = {c["key"] for c in data["categories"]}
    seen, errors, total = {}, [], 0
    for cat, terms in data["terms"].items():
        if cat not in keys:
            errors.append(f"unknown category {cat}")
        for t in terms:
            total += 1
            n = normalize(t)
            if not n:
                errors.append(f"empty term in {cat}: {t!r}")
            prev = seen.get(n)
            if prev and prev != cat:
                errors.append(f"conflict: {n!r} in {prev} and {cat}")
            seen[n] = cat
    for m, cat in data["modifiers"].items():
        if cat not in keys:
            errors.append(f"modifier {m} -> unknown {cat}")
    print(f"{total} terms, {len(seen)} unique normalized, {len(keys)} categories")
    if errors:
        print("\n".join(errors)); sys.exit(1)
    print("OK")

if __name__ == "__main__":
    main()
