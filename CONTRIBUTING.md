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

## How changes get in

`main` is protected. Nobody pushes to it directly, the maintainer included: every change arrives as a pull
request, has to pass CI, and is squash-merged.

1. **Fork** the repository and clone your fork.
2. **Branch** from an up-to-date `main` (`git switch -c fix/short-description`).
3. Make the change, run `swift test -c release`, and for engine changes `scripts/benchmark.sh`.
4. **Push to your fork** and open a pull request against `IftatBhuiyan/sandalphon:main`. Fill in the template.
5. CI runs the tests, the benchmark and a full app build. On a first contribution a maintainer has to approve
   the run before it starts, so it may sit for a while.
6. Review comments are resolved in the pull request; all threads must be resolved before it can merge.

Keep pull requests focused: one problem each. Bug fixes, wrong-correction fixes, word-list additions and
documentation are always welcome. For new behaviour or anything large, start a thread in
[Ideas](https://github.com/IftatBhuiyan/sandalphon/discussions/categories/ideas) first, so you do not spend
time on something that will not be merged.

Releases are cut by the maintainer from a signed, notarized build ([RELEASING.md](RELEASING.md)); release
tags (`v*`) are protected and pull requests should not change `VERSION`.

By contributing you agree that your work is released under the MIT licence.
