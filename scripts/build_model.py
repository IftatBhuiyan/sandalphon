#!/usr/bin/env python3
"""Packs the raw n-gram counts from build_ngrams.py into the files the app loads.

  python3 scripts/build_model.py COUNTS_DIR Data [min_bigram=10] [min_trigram=15]

Writes Data/conv_vocab.txt ("word count" per line, line number = id; id 0 is the sentence start),
Data/conv2.bin (u32 a, b, count; grouped by a, most frequent first) and
Data/conv3.bin (u32 a, b, c, count; grouped by a,b, most frequent first).
"""
import sys, os, struct
src, out = sys.argv[1], sys.argv[2]
min2 = int(sys.argv[3]) if len(sys.argv) > 3 else 10
min3 = int(sys.argv[4]) if len(sys.argv) > 4 else 15
ids = {"<s>": 0}
vocab = [["<s>", 0]]
for line in open(os.path.join(src, "uni.txt")):
    w, c = line.split()
    ids[w] = len(vocab); vocab.append([w, int(c)])
bi = []
for line in open(os.path.join(src, "bi.txt")):
    a, b, c = line.split(); c = int(c)
    if a == "<s>": vocab[0][1] += c
    if c >= min2: bi.append((ids[a], -c, ids[b]))
bi.sort()
tri = []
for line in open(os.path.join(src, "tri.txt")):
    a, b, c, n = line.split(); n = int(n)
    if n >= min3: tri.append((ids[a], ids[b], -n, ids[c]))
tri.sort()
with open(os.path.join(out, "conv_vocab.txt"), "w") as f:
    for w, c in vocab: f.write(f"{w} {c}\n")
with open(os.path.join(out, "conv2.bin"), "wb") as f:
    for a, c, b in bi: f.write(struct.pack("<III", a, b, -c))
with open(os.path.join(out, "conv3.bin"), "wb") as f:
    for a, b, n, c in tri: f.write(struct.pack("<IIII", a, b, c, -n))
print(len(vocab), len(bi), len(tri))
