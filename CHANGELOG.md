# Changelog

All notable changes to Sandalphon are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[semantic versioning](https://semver.org/).

## [1.0.1] - 2026-11-26

### Added
- A "Star on GitHub" menu item and a note on the Overview page that can be hidden for good. The app still
  sends nothing: no analytics, usage counts or crash reports.

### Changed
- New app icon in the studio's cut-paper style, with a dark-mode variant.

### Fixed
- The look-back pass no longer replaces a correct fix with a different word: "thier" became "their" and was
  then changed to "this" once more words followed.
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
