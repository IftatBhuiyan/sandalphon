# Contributing

Thanks for wanting to improve Sandalphon.

## Reporting a wrong correction

This is the most valuable kind of report. Please include:

1. Exactly what you typed, including the words around it.
2. What you ended up with, and what you expected.
3. The app you were typing in.

Please leave out anything private; a made-up sentence that reproduces the problem is ideal.

## Getting set up

```sh
swift test -c release           # 11 end-to-end typing tests, about a second
scripts/benchmark.sh            # quality numbers; --verbose shows example failures
scripts/build-app.sh --install  # run the real app
```

To see what the engine does with a sentence without running the app:

```sh
swift build -c release
.build/release/sandalphon-eval Data --type "teh quick brown fox "
.build/release/sandalphon-eval Data --explain jumsp fox     # ranked candidates with scores
```

## What makes a good change

- **Engine changes need numbers.** Run `scripts/benchmark.sh` before and after and put both in the pull
  request. A change that fixes more typos but also changes more correct words is usually not a win: a wrong
  correction costs the user far more than a missed one.
- **Add a test** in `Tests/TypeEngineTests` for any behaviour you fix. Tests type a sentence through the
  session and compare the result, so they are quick to write.
- **Nothing may block a keystroke.** Code on the key thread must not touch the disk, the network or another
  process. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- **Nothing typed may be logged or stored.** The diagnostics facility records positions and counts only.
- **Quiet by default.** New behaviour should work without showing anything on screen.

## Word lists

Missing a word, brand or common misspelling? The lists in `Data/` are plain text and documented in
[Data/README.md](Data/README.md). These are the easiest first contributions.

## Pull requests

Keep them focused, describe what changed and why, and make sure `swift test -c release` passes. By
contributing you agree that your work is released under the MIT licence.
