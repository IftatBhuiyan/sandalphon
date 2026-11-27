#!/usr/bin/env python3
"""Builds Data/misspellings_wikipedia.txt from Wikipedia's machine-readable list of common misspellings.

  curl -sL 'https://en.wikipedia.org/w/index.php?title=Wikipedia:Lists_of_common_misspellings/For_machines&action=raw' \
    | python3 scripts/build_misspellings.py Data

Keeps an entry only when the misspelling is not itself a word Sandalphon knows, there is exactly one
correction, and that correction is a single known word. The text is CC BY-SA 4.0 (see Data/README.md).
"""
import os, re, sys
data = sys.argv[1]
known = set()
for fn in ("unigrams.txt", "wordlist.txt", "extra.txt", "modern.txt"):
    for line in open(os.path.join(data, fn), encoding="utf-8-sig"):
        if not line.startswith("#") and line.split(): known.add(line.split()[0])
have = {line.split()[0] for line in open(os.path.join(data, "misspellings.txt"), encoding="utf-8") if line.split()}
word = re.compile(r"[a-z]+(?:'[a-z]+)*")
out = {}
for line in sys.stdin:
    if "->" not in line: continue
    wrong, right = (x.strip().lower() for x in line.split("->", 1))
    if "," in right or not word.fullmatch(wrong) or not word.fullmatch(right): continue
    if wrong in known or wrong in have or right not in known or wrong == right or len(wrong) < 4: continue
    out[wrong] = right
with open(os.path.join(data, "misspellings_wikipedia.txt"), "w", encoding="utf-8") as f:
    for w in sorted(out): f.write(f"{w} {out[w]}\n")
print(len(out), "entries")
