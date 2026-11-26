#!/usr/bin/env python3
"""Counts unigrams, bigrams and trigrams from plain text on stdin (one sentence per line),
restricted to the lexicon vocabulary, and writes raw counts to OUT_DIR.

  curl -sL https://object.pouta.csc.fi/OPUS-OpenSubtitles/v2018/mono/en.txt.gz | gunzip -c | head -c 600000000 \
    | python3 scripts/build_ngrams.py Data OUT_DIR
"""
import re, sys, os
data, out = sys.argv[1], sys.argv[2]
vocab = {"<s>": 0}
names = ["<s>"]
for fn in ("unigrams.txt", "extra.txt"):
    for line in open(os.path.join(data, fn), encoding="utf-8-sig"):
        if line.startswith("#"): continue
        p = line.split()
        if len(p) >= 2 and p[0] not in vocab and re.fullmatch(r"[a-z']+", p[0]):
            vocab[p[0]] = len(names); names.append(p[0])
B = 1 << 17
assert len(names) < B
tok = re.compile(r"[a-z]+(?:'[a-z]+)*")
uni, bi, tri = {}, {}, {}
get = vocab.get
n = 0
for line in sys.stdin.buffer:
    try: s = line.decode("utf-8").lower().replace("’", "'")
    except UnicodeDecodeError: continue
    a, b = -1, 0  # sentence start
    for w in tok.findall(s):
        c = get(w, -1)
        if c >= 0:
            uni[c] = uni.get(c, 0) + 1
            if b >= 0:
                k = b * B + c
                bi[k] = bi.get(k, 0) + 1
                if a >= 0:
                    k = (a * B + b) * B + c
                    tri[k] = tri.get(k, 0) + 1
        a, b = b, c
    n += 1
    if n % 2000000 == 0: print(n, len(bi), len(tri), file=sys.stderr, flush=True)
with open(os.path.join(out, "uni.txt"), "w") as f:
    for k, v in sorted(uni.items(), key=lambda x: -x[1]): f.write(f"{names[k]} {v}\n")
with open(os.path.join(out, "bi.txt"), "w") as f:
    for k, v in bi.items():
        if v >= 4: f.write(f"{names[k // B]} {names[k % B]} {v}\n")
with open(os.path.join(out, "tri.txt"), "w") as f:
    for k, v in tri.items():
        if v >= 4: f.write(f"{names[k // B // B]} {names[k // B % B]} {names[k % B]} {v}\n")
print("done", n, file=sys.stderr)
