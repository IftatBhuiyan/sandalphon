# Architecture

Sandalphon is a Swift package with three targets.

| Target | Role |
|---|---|
| `TypeEngine` | The correction engine. Pure Swift, no AppKit. Everything here is unit tested. |
| `Sandalphon` | The menu-bar app: keyboard tap, Accessibility, suggestion bar, settings window, updater. |
| `sandalphon-eval` | A command-line tool that measures the engine. `scripts/benchmark.sh` drives it. |

## The engine (`Sources/TypeEngine`)

**`Lexicon`** loads the data in `Data/`: a vocabulary with blended web and conversational frequencies, a trie
over it, web bigrams, and conversational bigram and trigram counts.

**`KeyboardModel`** prices individual typing errors. A transposition costs 0.5, hitting a neighbouring key
0.55, leaving out one of a doubled letter 0.5, a missing apostrophe 0.1, an arbitrary substitution 1.0, and
errors on the first letter cost more.

**`Engine`** does the ranking.
- *Candidates* come from a depth-first walk of the trie that carries a weighted Damerau-Levenshtein row per
  node and prunes branches that cannot come in under the cost limit for the word's length.
- *Scoring* is `γ · log P(word | previous two words) − α · error cost`. `P` interpolates trigram, bigram and
  unigram estimates and adds what the user has typed before.
- *Deciding to change a word outright* takes more than being the best candidate: it must be clearly ahead of
  the runner-up, cheap enough to be a plausible slip, and a reasonably common word. Unknown capitalised words
  mid-sentence are treated as names and left alone.
- `reconsider` re-scores a finished word with the words on both sides of it, for the look-back pass.
- `pairFix` handles slips that only show with two words side by side (*could of*, *a apple*, *the the*).

**`TypingSession`** is the state machine. It is fed one key at a time and answers with an `Edit` (delete n
characters, insert text) when something should change. It tracks the word in progress, the sentence context,
and everything typed since the caret last moved, so it knows exactly how far back an earlier word is.
It never sees the document; when it is not sure what is before the caret it stays hands-off until the next
space.

**`UserModel`** holds what has been learned: word, pair and triple counts, words whose correction was undone,
and how unknown words are capitalised. A slip that gets corrected is taken back out, so mistakes are not
learned as habits.

## The app (`Sources/Sandalphon`)

**Threading** is the core of the design, because typing latency matters more than anything else.

- The event tap, the `TypingSession` and the engine live on one dedicated high-priority thread. Handling a
  key is in-memory work only.
- Suggestions and the look-back plan are computed after the key has been passed on.
- The Accessibility API is slow and cross-process, so it is only called from a separate queue. Its results
  are applied only if no key has arrived in the meantime.
- The suggestion bar is drawn on the main thread.

**Safety checks.** After each key, the text before the caret is read back and compared with what the session
believes was typed. On a mismatch (an app that autocompletes, a selection, a slow field) the session goes
hands-off. A look-back revision is only armed after such a check has confirmed the last 100 characters, and it
is injected immediately ahead of the next key so it cannot interleave with typing.

**`KeyTranslator`** converts key code plus modifiers into a character with the current keyboard layout, because
the string carried by a key event does not always reflect its own modifier flags.

**`FocusReader`** wraps the Accessibility calls: focused element, role, text before the caret, caret
rectangle (with the text-marker API for web content), and whether the field is a password, search or address
field.

## Adding a language

The engine assumes words made of `a-z` and apostrophes. Supporting another language means widening the
alphabet in `Lexicon.swift`, supplying a key-adjacency layout in `KeyboardModel`, and providing the same data
files: word frequencies, pair counts and, ideally, triple counts from conversational text.
