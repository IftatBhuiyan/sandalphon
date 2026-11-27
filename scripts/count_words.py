#!/usr/bin/env python3
"""Counts every word in plain text on stdin, with how often it is capitalised in the middle of a sentence.

  python3 scripts/count_words.py < corpus.txt > word_counts.txt

Output lines: word total mid_sentence capitalised_mid_sentence all_caps_mid_sentence (words seen 3+ times).
Used by build_wordlist.py to decide which dictionary words are worth knowing and which are names.
"""
import re, sys, collections
tok = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)*")
total = collections.Counter(); mid = collections.Counter(); cap = collections.Counter(); upper = collections.Counter()
for raw in sys.stdin.buffer:
    try: s = raw.decode("utf-8").replace("’", "'")
    except UnicodeDecodeError: continue
    start = True
    pos = 0
    for m in tok.finditer(s):
        w = m.group(); lw = w.lower()
        between = s[pos:m.start()]
        if any(c in between for c in ".!?:\"-"): start = True
        total[lw] += 1
        if not start:
            mid[lw] += 1
            if w[0].isupper(): cap[lw] += 1
            if len(w) > 1 and w.isupper(): upper[lw] += 1
        start = False
        pos = m.end()
for w, n in total.most_common():
    if n < 3: break
    print(w, n, mid[w], cap[w], upper[w])
