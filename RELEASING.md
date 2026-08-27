# Releasing CallScribe

Colleagues never touch a terminal — they get a DMG, drag it to Applications, and
every later version arrives as an in-app update prompt.

## One-time setup (Chris)

1. **Developer ID certificate.** At
   [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates)
   create a **Developer ID Application** certificate, download the `.cer`, and
   double-click to install. The existing *Apple Development* certificate cannot
   be used — Gatekeeper rejects it on other people's Macs.

2. **Notarization credentials.** Create an app-specific password at
   [account.apple.com](https://account.apple.com) ▸ Sign-In and Security, then:

   ```sh
   xcrun notarytool store-credentials "CallScribe" \
       --apple-id "chris@skyline.at" \
       --team-id "<TEAM_ID>" \
       --password "<app-specific-password>"
   ```

3. **Update key.** Already generated; the private half is in your login keychain
   (`Sparkle EdDSA private key`) and the public half is in `sparkle_public_key`.
   **Back the private key up** — losing it means no existing install can ever be
   updated again, and everyone has to reinstall by hand.

4. **Hosting.** Pick a URL to serve two files and set it once in `build.sh`
   (`SUFeedURL`) and `release.sh` (`DOWNLOAD_BASE`). Any static host works —
   a Vercel project or an S3 bucket is plenty.

## Cutting a release

```sh
echo "1.1.0" > VERSION
git commit -am "Release 1.1.0"
./release.sh
```

Then upload `dist/CallScribe-1.1.0.dmg` and `dist/appcast.xml` to the hosting
URL. Everyone's app checks that appcast daily and offers the update in place.

`generate_appcast` reads release notes from `dist/CallScribe-<version>.html` if
you write one — otherwise the update prompt just shows the version number.
