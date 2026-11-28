# Changelog

All notable changes to Sandalphon are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[semantic versioning](https://semver.org/).

## [1.2.0] - 2026-11-28

### Added
- Wrong-but-real words are put right from the words around them: *their/there/they're*, *your/you're*,
  *its/it's*, *then/than*, *loose/lose*, *to/too*, *affect/effect*, *who's/whose*, *were/where/we're*. It waits
  for two more words and acts only on strong evidence; on unseen text it changed 7 of about 73,000 correct uses,
  all of them real mistakes.
- Text shortcuts: type a key such as `;addr` and a space, and it becomes its text. Add, edit and remove them in
  Settings › Shortcuts; they are kept in one file on your Mac. Delete straight after puts the key back.
- Undo from anywhere: ⌃⌥Z puts back the latest correction even after you have kept typing, and the menu bar
  lists the last ten under Recent Corrections. The list is kept in memory only.
- Install with Homebrew: `brew install --cask iftatbhuiyan/tap/sandalphon`.
- A browser demo of the engine, compiled to WebAssembly (`scripts/build-web.sh`, docs/WEB.md).
- With the diagnostics log on, each key press records where it came from (a keyboard or software that types),
  never which key.

### Changed
- A clearer settings window: setup comes first and disappears once done, each switch has a one-line
  explanation, related settings are grouped, keys are shown as keycaps, and the other pages say when
  Accessibility access is still missing.
- The menu bar icon is now the wing and text cursor from the app icon.

## [1.1.0] - 2026-11-27

### Added
- About 14,000 more words: American spellings (*favorite*, *theater*, *traveling* were being changed to the
  British forms), interjections (*oh*, *um*), spoken contractions (*what'd*, *there'll*), acronyms and many
  names and places, with their capitals (*fbi* → *FBI*, *london* → *London*).
- About 3,800 well-known misspellings from Wikipedia's list are fixed outright.
- The surname after a title is capitalised: *mr smith* → *Mr Smith*.
- A "Star on GitHub" menu item and a note on the Overview page that can be hidden for good. The app still
  sends nothing: no analytics, usage counts or crash reports.
- A benchmark of real misspellings inside real sentences (`sandalphon-eval --context`).

### Changed
- New app icon in the studio's cut-paper style, with a dark-mode variant.

### Fixed
- Everyday words missing from the vocabulary were "corrected": *oh* → *on*, *mr* → *me*, *fbi* → *fib*.
- The look-back pass no longer replaces a correct fix with a different word: "thier" became "their" and was
  then changed to "this" once more words followed.
- Single letters and possessives of known words (*my mother's*) are never changed.
- `scripts/build-app.sh` failed when run without `--universal`.

## [1.0.0] - 2026-11-26

First public release.

### Added
- System-wide autocorrect that fixes a word when you press space or punctuation, with Backspace to undo.
- Going back to fix an earlier word once the words after it show it was wrong.
- Sentence capitals, capitals for names, places and brands, and fixes for common two-word grammar slips.
- Double space for a full stop, and removal of a stray space before a comma.
- On-demand suggestions with Option-Escape, for the word at the caret or a selected word.
- A "Fix Typos with Sandalphon" entry in the Services menu for selected text.
- Learning of your own words and phrases, stored only on your Mac.
- A settings window, a menu-bar menu, per-app exclusions and automatic updates.
