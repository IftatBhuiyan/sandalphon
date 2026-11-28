# The browser demo

The "Try it here" box on [the Sandalphon page](https://www.eclipsestudios.io/apps/sandalphon) runs this
repository's `TypeEngine`, compiled to WebAssembly. It is the same code as the app: the page sends each key to
`TypingSession.type(_:into:)`, the function the tests drive through `simulate(typing:)`.

- **Nothing leaves the browser.** The worker (`web/worker.js`) downloads the engine and the word data from the
  website when someone presses Start, then only talks to the page. Learning is off and nothing is stored.
- **Size.** About 12.4 MB compressed: the engine is 2.9 MB and the word data 9.5 MB. Nothing is fetched until
  the demo is started.
- **One difference from the app.** The app applies a look-back fix just before your next key, once it has
  checked the text field; the demo applies it after a short pause, so you can see it happen.

## Building

You need swift.org's open-source toolchain and its WebAssembly SDK, of the same version, and `wasm-opt`.
They are installed alongside Xcode and do not replace its `swift`:

```sh
curl -O https://download.swift.org/swift-6.4.3-release/xcode/swift-6.4.3-RELEASE/swift-6.4.3-RELEASE-osx.pkg
installer -target CurrentUserHomeDirectory -pkg swift-6.4.3-RELEASE-osx.pkg
~/Library/Developer/Toolchains/swift-6.4.3-RELEASE.xctoolchain/usr/bin/swift sdk install \
  https://download.swift.org/swift-6.4.3-release/wasm-sdk/swift-6.4.3-RELEASE/swift-6.4.3-RELEASE_wasm.artifactbundle.tar.gz \
  --checksum 5f24408dc9737ce4cb23b7e3ed4306cabfa02cc02f22ab260b14579b955d4b12
brew install binaryen
```

Then:

```sh
scripts/build-web.sh path/to/website/public/sandalphon-demo
```

It writes the gzipped engine and data, the worker, the WASI shim
([@bjorn3/browser_wasi_shim](https://github.com/bjorn3/browser_wasi_shim), fetched from npm at a pinned version
and served from the site, MIT or Apache-2.0), the licences, and `manifest.json`, which records the commit the
engine was built from.

For WebAssembly the engine imports `FoundationEssentials` only, which keeps it about 50 MB smaller;
`Sources/TypeEngine/WASICompat.swift` fills the few gaps.

## Checking it matches the app

```sh
while IFS= read -r l; do .build/release/sandalphon-eval Data --type "$l " | sed -n 2p; done < web/parity.txt > native.txt
node web/parity.mjs .build-wasm/release/sandalphon-web.wasm Data < web/parity.txt > wasm.txt
diff native.txt wasm.txt
```

The two must be identical, and both must report the same number of words loaded. If a data file fails to load
under WebAssembly the engine still starts but corrects worse, so this diff is the check that matters.
