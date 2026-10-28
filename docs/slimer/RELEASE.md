# Slimer release pipeline

Workflow: `.github/workflows/slimer-release.yml`. Run it manually with a version, or push a tag `slimer-vX.Y.Z`.

## One-time setup

1. **GitHub repo.** Push this repository to GitHub (e.g. `<you>/slimer`). Keep `upstream` pointing at ghostty-org/ghostty.
2. **Developer ID certificate.** In Xcode or developer.apple.com create a *Developer ID Application* certificate, export it as `.p12` with a password, then:
   `base64 -i cert.p12 | pbcopy` → secret `MACOS_CERTIFICATE`; the password → `MACOS_CERTIFICATE_PWD`; the identity string (`security find-identity -v -p codesigning`) → `MACOS_CERTIFICATE_NAME`; any random string → `MACOS_CI_KEYCHAIN_PWD`.
3. **Notarization.** App Store Connect → Users and Access → Integrations → App Store Connect API → create a key with *Developer* role. Secrets: `APPLE_NOTARIZATION_ISSUER`, `APPLE_NOTARIZATION_KEY_ID`, `APPLE_NOTARIZATION_KEY` (the `.p8` contents).
4. **Sparkle keys.** From the Sparkle distribution (`bin/generate_keys`): run `generate_keys` once (stores the private key in your login keychain), then `generate_keys -p` prints the public key → `SPARKLE_KEY_PUB`, and `generate_keys -x key.txt` exports the private key → `SPARKLE_KEY_PRIV`. Delete `key.txt` after uploading.
5. **Feed URL.** Once the first release exists, set the appcast URL in `macos/Sources/Features/Update/UpdateDelegate.swift` (`feedURLString`) to `https://github.com/<you>/slimer/releases/latest/download/appcast.xml`. Until then the app never checks for updates (intentional, see the rebrand commit).

## Local unsigned builds

`zig build -Doptimize=ReleaseFast -Demit-macos-app=false && macos/build.nu --configuration ReleaseLocal` produces an ad-hoc signed app at `macos/build/ReleaseLocal/Ghostty.app` for personal use on this Mac. The first launch needs a right-click → Open because it is not notarized.

## Why the bundle id changed

Slimer uses `top.mayhem.slimer` so it installs beside stock Ghostty with separate defaults, Accessibility permission, and update feed. The internal product name stays `Ghostty` to keep the diff against upstream small.
