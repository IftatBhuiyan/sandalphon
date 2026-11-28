#!/bin/bash
# Measures correction quality. Downloads two public misspelling test sets on first run (not redistributed).
#   scripts/benchmark.sh            summary
#   scripts/benchmark.sh --verbose  with examples of each kind of failure
set -euo pipefail
cd "$(dirname "$0")/.."
CACHE=.cache/benchmark
mkdir -p "$CACHE"
for f in spell-testset1.txt spell-testset2.txt; do
  [[ -s "$CACHE/$f" ]] || curl -sfL -o "$CACHE/$f" "https://norvig.com/$f"
done
[[ -s "$CACHE/holbrook-tagged.dat" ]] || curl -sfL -o "$CACHE/holbrook-tagged.dat" "https://www.dcs.bbk.ac.uk/~ROGER/holbrook-tagged.dat"
# Valid words the dictionary does not know: lowercase first names, and a sample of rare dictionary words.
[[ -s "$CACHE/names_lower.txt" ]] || tr 'A-Z' 'a-z' < /usr/share/dict/propernames > "$CACHE/names_lower.txt"
[[ -s "$CACHE/rare.txt" ]] || awk 'length($0)>=5 && /^[a-z]+$/' /usr/share/dict/words | awk 'NR%60==0' > "$CACHE/rare.txt"
swift build -c release --product sandalphon-eval >/dev/null
EVAL=.build/release/sandalphon-eval
echo "== Slips of the fingers on common words (synthetic) =="
$EVAL Data | grep -E "real words changed|synthetic slips|per word|misspellings fixed" | cut -c1-160
echo "== Human misspellings, no context (Birkbeck sets via norvig.com) =="
for f in spell-testset1.txt spell-testset2.txt; do $EVAL Data --testset "$CACHE/$f" "$@" | tail -n +2; done
echo "== Misspellings in context (Holbrook: schoolchildren's writing, a hard set) =="
$EVAL Data --context "$CACHE/holbrook-tagged.dat" "$@" | tail -n +3
echo "== Valid words it does not know (lower is better) =="
echo "first names, lowercase: $($EVAL Data --unknown "$CACHE/names_lower.txt" "$@" | tail -n +2)"
echo "rare dictionary words:  $($EVAL Data --unknown "$CACHE/rare.txt" "$@" | tail -n +2)"
if [[ -n "${SANDALPHON_HELDOUT:-}" ]]; then
  echo "== Going back to fix earlier words (held-out sentences) =="
  $EVAL Data --retro "$SANDALPHON_HELDOUT" | grep -E "^correct|^planted"
  echo "== Confusable real words (their/there, your/you're...) in held-out sentences =="
  $EVAL Data --confusables "$SANDALPHON_HELDOUT" | tail -n +2
fi
