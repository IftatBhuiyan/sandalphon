#!/usr/bin/env python3
"""Builds Data/wordlist.txt: words the base frequency list lacks, taken from SCOWL and sized by how often
they turn up in conversation.

  python3 scripts/build_wordlist.py SCOWL_FINAL_DIR WORD_COUNTS Data

SCOWL_FINAL_DIR is the `final` folder of a SCOWL release (http://wordlist.aspell.net/).
WORD_COUNTS is the output of scripts/count_words.py over the same subtitle text the n-gram model is built from.

The base list (unigrams.txt) has no American spellings such as "favorite", no interjections ("oh", "um"),
few abbreviations ("Mr", "FBI") and few names. This adds them, and records which words are written with a
capital so that "london" and "james" come out right.

Output lines are `word count [Display]` on the scale of unigrams.txt, or `word Display` for a word that is
already known and only needs its capital.
"""
import os, re, sys

scowl, counts_path, data = sys.argv[1], sys.argv[2], sys.argv[3]
WORD = re.compile(r"[a-z]+(?:'[a-z]+)*")
DIALECTS = ("english", "american", "british", "british_z", "canadian", "australian")

known, has_display = {}, set()
for fn in ("unigrams.txt", "extra.txt", "modern.txt"):
    for line in open(os.path.join(data, fn), encoding="utf-8-sig"):
        if line.startswith("#"): continue
        p = line.split()
        if len(p) >= 2:
            known.setdefault(p[0], fn)
            if len(p) >= 3 or not p[1].replace(".", "").isdigit(): has_display.add(p[0])
for line in open(os.path.join(data, "display.txt"), encoding="utf-8"):
    p = line.split()
    if len(p) == 2: has_display.add(p[0])

total, mid, cap, upper = {}, {}, {}, {}
for line in open(counts_path, encoding="utf-8"):
    w, n, m, c, u = line.split()
    total[w], mid[w], cap[w], upper[w] = int(n), int(m), int(c), int(u)
scale = 23135851162 / total["the"]

lower, cased = {}, {}   # word -> smallest SCOWL size it appears at; cased also keeps the spelling
for fn in os.listdir(scowl):
    m = re.fullmatch(r"([a-z_]+)-([a-z-]+)\.(\d+)", fn)
    if not m or m.group(1) not in DIALECTS: continue
    kind, size = m.group(2), int(m.group(3))
    for raw in open(os.path.join(scowl, fn), encoding="latin-1"):
        w = raw.strip()
        if not w: continue
        lw = w.lower()
        if not WORD.fullmatch(lw) or len(lw) > 24: continue
        if kind in ("words", "contractions") and w == lw:
            # Contractions are filed as rare however common they are in speech ("what'd", "there'll").
            lower[lw] = min(lower.get(lw, 99), min(size, 70) if kind == "contractions" else size)
        elif kind in ("upper", "proper-names", "abbreviations") or w != lw:
            if lw.endswith("'s"): continue                      # possessives are handled by the engine
            if size < cased.get(lw, (99, ""))[0]: cased[lw] = (size, w)

# Two-letter strings are nearly all noise (units, chemical symbols, subtitle debris), and treating them as
# words would stop real typos such as "th" being fixed. Only these are taken.
TWO = {"oh": None, "uh": None, "ah": None, "um": None, "mm": None, "eh": None, "ow": None, "aw": None,
       "er": None, "hm": None, "ha": None, "ho": None, "ma": None, "pa": None, "ex": None, "ad": None,
       "ox": None, "mr": "Mr", "dr": "Dr", "ms": "Ms", "jr": "Jr", "sr": "Sr", "uk": "UK", "dj": "DJ",
       "hq": "HQ", "iq": "IQ", "vp": "VP", "vs": None}

NOT_NAMES = {"japs", "mays", "cong", "frau", "herr", "lieut", "mlle", "okla", "capt", "anglo", "brest", "ming"}

def count_for(w, floor):
    return max(int(total.get(w, 0) * scale), floor)

def mostly_capital(w, share=0.9, least=40):
    return mid.get(w, 0) >= least and cap.get(w, 0) >= share * mid[w]

out = []
# Ordinary words: everything common, and rarer ones only if people actually say them.
for w, size in lower.items():
    if w in known or len(w) <= 2 or w.endswith("'s"): continue
    seen = total.get(w, 0)
    if size <= 50 or (size <= 70 and seen >= 4 and len(w) >= 4):
        out.append((w, count_for(w, 200000), None))
# Names, places, acronyms: need to be seen in use, or be very common, and must not double as a plain word.
display_only = []
for w, (size, spelling) in cased.items():
    if len(w) <= 2 or lower.get(w, 99) <= 70: continue
    seen = total.get(w, 0)
    acronym = spelling.isupper() or spelling[1:] != spelling[1:].lower()
    if w in known:
        # Already a word in the base list: give it its capital when that is how it is nearly always written.
        if w in NOT_NAMES: continue
        if w not in has_display and size <= 60 and not acronym and len(w) >= 4 and mostly_capital(w):
            display_only.append((w, spelling))
        continue
    if acronym:
        # Kept when it is common, or when people really do write it in capitals.
        written_upper = mid.get(w, 0) >= 10 and upper.get(w, 0) >= 0.5 * mid[w]
        if size <= 40 or (size <= 80 and seen >= 8 and written_upper):
            out.append((w, count_for(w, 200000), spelling))
    elif len(w) <= 4:
        # A short name is easily a typo of something else, so only well-known ones.
        if size <= 50 and (seen >= 8 or size <= 40):
            out.append((w, count_for(w, 200000), spelling))
    elif size <= 40 or (size <= 80 and seen >= 8 and mostly_capital(w, 0.8, 6)):
        out.append((w, count_for(w, 200000), spelling))

for w, spelling in TWO.items():
    if w not in known: out.append((w, count_for(w, 200000), spelling))
out.sort(key=lambda r: (-r[1], r[0]))
with open(os.path.join(data, "wordlist.txt"), "w", encoding="utf-8") as f:
    f.write("# Generated by scripts/build_wordlist.py from SCOWL and subtitle word counts. Do not edit by hand;\n")
    f.write("# put corrections in extra.txt. Format: word count [Display]  or  word Display\n")
    for w, c, d in out:
        f.write(f"{w} {c} {d}\n" if d else f"{w} {c}\n")
    for w, d in sorted(display_only):
        f.write(f"{w} {d}\n")
print(f"added {len(out)} words ({sum(1 for r in out if r[2])} with a capital), {len(display_only)} capitals for known words")
