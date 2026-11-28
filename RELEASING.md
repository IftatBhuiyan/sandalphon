# Releasing

Releases are cut from a maintainer's Mac, because signing needs the Developer ID certificate and the update
signing key, neither of which lives in the repository or in CI.

## One-time setup

- A **Developer ID Application** certificate in the login keychain.
- An **App Store Connect API key** for notarization, described by `ASC_KEY_ID`, `ASC_ISSUER_ID` and
  `ASC_KEY_PATH` (the script also reads `~/.private_keys/appstoreconnect.env`).
- The **update signing key** at `~/.config/sandalphon/sparkle_ed25519_private.key`. Its public half is
  `Resources/sparkle_public_key.txt`. Every installed copy trusts updates signed with this key, so keep a
  backup somewhere safe: if it is lost, existing installs can no longer be updated.
- The GitHub CLI, signed in.

## Cutting a release

1. Update `VERSION` and add a section to `CHANGELOG.md`.
2. Commit and push to `main`, and wait for CI to pass.
3. Run `scripts/release.sh`.

The script runs the tests, builds a universal app, signs and notarizes the DMG, signs it for the in-app
updater, writes `appcast.xml`, tags the commit and publishes a GitHub release with both files attached.
Installed copies find the new version through
`https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml`.

## Homebrew

`release.sh` finishes by running `scripts/update-tap.sh`, which sets the version and sha256 of the cask in
[IftatBhuiyan/homebrew-tap](https://github.com/IftatBhuiyan/homebrew-tap) from the published DMG. If it fails,
the release itself is fine; run `scripts/update-tap.sh <version>` once the problem is fixed. The cask has
`auto_updates true`, so Homebrew leaves updating to Sparkle.
