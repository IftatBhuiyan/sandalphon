#!/bin/bash
# Builds the browser demo: the engine compiled to WebAssembly, its word data, and the worker that runs it.
#   scripts/build-web.sh OUT_DIR
# Needs the swift.org toolchain and Wasm SDK of the version below (see docs/WEB.md) and wasm-opt (binaryen).
# Xcode's own Swift is left alone: this script calls the open-source toolchain by path.
set -euo pipefail
OUT="${1:?usage: scripts/build-web.sh OUT_DIR}"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
cd "$(dirname "$0")/.."
SWIFT_VERSION=6.4.3
TOOLCHAIN="$HOME/Library/Developer/Toolchains/swift-$SWIFT_VERSION-RELEASE.xctoolchain/usr/bin"
SDK="swift-$SWIFT_VERSION-RELEASE_wasm"
SHIM_VERSION=0.4.2
DATA=(unigrams.txt bigrams.txt wordlist.txt extra.txt modern.txt display.txt misspellings.txt
      misspellings_wikipedia.txt phrases.txt conv_vocab.txt conv2.bin conv3.bin)

[[ -x "$TOOLCHAIN/swift" ]] || { echo "missing $TOOLCHAIN (see docs/WEB.md)" >&2; exit 1; }
command -v wasm-opt >/dev/null || { echo "missing wasm-opt: brew install binaryen" >&2; exit 1; }

"$TOOLCHAIN/swift" build -c release --product sandalphon-web --swift-sdk "$SDK" --scratch-path .build-wasm \
  -Xswiftc -Xclang-linker -Xswiftc -mexec-model=reactor
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
wasm-opt -Oz --strip-debug --strip-producers --enable-bulk-memory --enable-sign-ext --enable-mutable-globals \
  --enable-nontrapping-float-to-int .build-wasm/release/sandalphon-web.wasm -o "$WORK/engine.wasm"

rm -rf "$OUT"; mkdir -p "$OUT/data" "$OUT/wasi"
COMMIT="$(git rev-parse --short HEAD)"
[[ -z "$(git status --porcelain)" ]] || COMMIT="$COMMIT+local changes"
ENGINE="engine-$(shasum -a 256 "$WORK/engine.wasm" | cut -c1-10).wasm.gz"   # new name when it changes
gzip -9 -c "$WORK/engine.wasm" > "$OUT/$ENGINE"
for f in "${DATA[@]}"; do gzip -9 -c "Data/$f" > "$OUT/data/$f.gz"; done
cp web/worker.js "$OUT/worker.js"
cp Data/README.md "$OUT/data/README.md"   # sources and licences of the data, including the SCOWL notice
cp LICENSE "$OUT/LICENSE.txt"

# The WASI shim comes from npm at a pinned version and is served from this site, not a CDN.
( cd "$WORK" && npm pack --silent "@bjorn3/browser_wasi_shim@$SHIM_VERSION" >/dev/null && tar xzf ./*.tgz )
cp "$WORK"/package/dist/*.js "$OUT/wasi/"
cp "$WORK"/package/LICENSE-MIT "$WORK"/package/LICENSE-APACHE "$OUT/wasi/"

python3 - "$OUT" "$ENGINE" "$COMMIT" "${DATA[@]}" <<'PY'
import json, os, sys
out, engine, commit, names = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
data = [{"name": n, "bytes": os.path.getsize(f"{out}/data/{n}.gz")} for n in names]
total = os.path.getsize(f"{out}/{engine}") + sum(d["bytes"] for d in data)
json.dump({"engine": engine, "commit": commit, "bytes": total, "data": data}, open(f"{out}/manifest.json", "w"), indent=1)
print(f"web demo in {out}: {total / 1e6:.1f} MB to download (engine {commit})")
PY
