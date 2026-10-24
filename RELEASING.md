# Releasing CallScribe

Colleagues never touch a terminal: they install the DMG once, and every later
version arrives in the app (Sparkle, `Sources/CallScribe/Updater.swift`).

The feed is `appcast.xml` on `main`, read through raw.githubusercontent.com;
the DMGs are GitHub release assets. Both have to stay public for updates to
reach anyone.

## One-time setup

1. **Developer ID Application certificate** — Xcode ▸ Settings ▸ Accounts ▸
   team AF86JFLJ32 ▸ Manage Certificates… ▸ + ▸ Developer ID Application.
   *Apple Development* certificates don't work: Gatekeeper rejects them on
   other Macs.

2. **Notarization credentials** — an app-specific password from
   [account.apple.com](https://account.apple.com) ▸ Sign-In and Security, then
   once (it asks for the password):

   ```sh
   xcrun notarytool store-credentials CallScribe --apple-id <your Apple ID> --team-id AF86JFLJ32
   ```

3. **Update key** — the private half is in the login keychain (Sparkle's
   `ed25519` item); the public half is `sparkle_public_key`, baked into every
   build. `.build/artifacts/sparkle/Sparkle/bin/generate_keys -p` prints the
   keychain's public half — it must match the file. **Back the private key up**
   (`generate_keys -x <file>`): without it no installed copy can ever be updated
   again, and everyone reinstalls by hand.

## Cutting a release

```sh
echo "1.2.0" > VERSION
git commit -am "Release 1.2.0"
NOTES='<ul><li>What changed, in a line or two.</li></ul>' ./release.sh --publish
```

`release.sh` refuses a dirty tree or a version already in the feed. It builds
with the Developer ID and the hardened runtime, notarizes and staples the app
and the DMG, signs the DMG for Sparkle and lists it first in `appcast.xml`.
With `--publish` it then pushes, creates the `v1.2.0` GitHub release with the
DMG, and commits and pushes the feed — the DMG goes up before the feed points
at it. Without `--publish` it stops after the DMG and prints those steps.

Sparkle decides what's newer by `CFBundleVersion`, which is the commit count
(`git rev-list --count HEAD`), so releases come from `main` only.
