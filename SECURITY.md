# Security

Sandalphon reads every key you type in order to correct it. That makes its security and privacy properties
the most important thing about it.

## What it does and does not do

- All processing happens on your Mac. What you type is never sent anywhere, and your text itself is never
  written to disk.
- The only network request is the update check against this repository's GitHub releases. It can be turned
  off in Settings, and updates are verified with an EdDSA signature before they are installed.
- It learns words and short phrases (up to three words) you use more than once and stores those counts in
  `~/Library/Application Support/Sandalphon/user.json`, readable only by your account and excluded from Time
  Machine. A word or phrase typed only once is not saved, with one exception: when you undo a
  correction, the word you typed is listed so it is not corrected again. You can inspect or erase it from Settings › Privacy.
- Text shortcuts you create in Settings › Shortcuts are stored in
  `~/Library/Application Support/Sandalphon/shortcuts.json`, readable only by your account. They are only what
  you entered there, never anything typed elsewhere, and can be deleted from Settings › Privacy.
- Password fields are invisible to it: macOS withholds their keystrokes from every app. A field that shows
  a password as you type (a "show password" toggle) is an ordinary text field to macOS, so Sandalphon treats
  it like any other; turn Sandalphon off in apps where you type secrets in the open.
- It contains no analytics, telemetry or crash reporting.

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub's
[private vulnerability reporting](../../security/advisories/new) for this repository. You should get a reply
within a week. Reports about anything that could expose what a person types are treated as critical.

## Verifying a download

Release builds are signed with a Developer ID certificate and notarized by Apple. You can check a copy with:

```sh
codesign --verify --deep --strict /Applications/Sandalphon.app
spctl --assess --type execute -vv /Applications/Sandalphon.app
```

The app can also be built from source; see the README.
