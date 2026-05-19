# Clipen — Sparkle auto-updates

The app uses [Sparkle 2](https://sparkle-project.org) with feed URL:

**`https://raw.githubusercontent.com/pinni-vamshi/clipen-releases/main/appcast.xml`**

(set in `paste/SparkleInfo.plist`)

Public releases repo (DMGs only, no source): **https://github.com/pinni-vamshi/clipen-releases**

## Option A — Host on the `clipen.app` domain (recommended once DNS is set up)

1. Point `clipen.app` DNS at any static host (Cloudflare Pages, GitHub Pages with a custom domain, Netlify, S3+CloudFront, etc.).
2. Publish `appcast.xml` at `https://clipen.app/appcast.xml`.
3. Publish each DMG at the URL prefix used when running `generate_appcast` — by default `https://clipen.app/download/`.

No code changes needed; `SUFeedURL` is already this URL.

## Option B — Host on GitHub Releases (free, zero DNS, works in ~5 min)

Best when you don't want to deal with hosting yet. Sparkle is happy with any HTTPS URL.

1. Create a public repo, e.g. `https://github.com/<you>/clipen-releases`.
2. In `paste/SparkleInfo.plist`, change `SUFeedURL` to:
   ```
   https://raw.githubusercontent.com/<you>/clipen-releases/main/appcast.xml
   ```
3. In `dist/release.sh`, change the `--download-url-prefix` to the release-asset URL pattern for your repo, e.g.:
   ```bash
   "$GEN" --download-url-prefix "https://github.com/<you>/clipen-releases/releases/download/v${VERSION}/" dist/
   ```
4. For each release: create a new GitHub Release tagged `v<VERSION>`, upload the `.dmg`, and commit the regenerated `dist/appcast.xml` to the repo's `main` branch.

Once `SUFeedURL` is changed, **every previously-shipped build keeps checking the old URL** — so make sure the *first* release that ships a new feed URL is one users will install before you stop hosting the old URL. (For a v0/v1 app with no users in the field, this is a non-issue: just change it.)

## Signing key (EdDSA)

A public key is in `paste/SparkleInfo.plist` as **`SUPublicEDKey`**. The matching **private** key lives in your macOS Keychain (Sparkle’s `generate_keys` tool put it there when we ran it on this machine).

**Do not lose that machine’s keychain backup** — every DMG you publish must be signed with the same private key, or updates will be rejected.

If you ever need a new key pair:

```bash
# After Xcode has resolved the Sparkle package once:
"$(find ~/Library/Developer/Xcode/DerivedData -path '*SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys' 2>/dev/null | head -1)"
```

Copy the printed `SUPublicEDKey` into `paste/SparkleInfo.plist`, rebuild, and **re-sign all future DMGs** with the new key. Old installs cannot verify updates signed with a different key.

## Each release

1. In Xcode: bump **`MARKETING_VERSION`** (e.g. `1.0` → `1.0.1`) and **`CURRENT_PROJECT_VERSION`** (build number must **increase** every upload — Sparkle compares this).
2. Build & notarize: from repo root, `./dist/release.sh --notarize`.
3. Generate / refresh the appcast (paths adjust to your DerivedData if needed):

```bash
GEN="$(find ~/Library/Developer/Xcode/DerivedData -path '*SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast' 2>/dev/null | head -1)"
"$GEN" --download-url-prefix "https://clipen.app/download/" dist/
# Upload dist/appcast.xml + the new DMG to your host so URLs match the feed.
```

4. Upload **`dist/appcast.xml`** to `https://clipen.app/appcast.xml` and the DMG to the URL prefix you used.

## In the app

- **Main window** footer: **Check for updates** → Sparkle UI.
- **Menu bar icon** (right-click): **Check for Updates…**
- Automatic check: once per **86400** seconds (daily), when the app is running.

## Repo files

- `paste/SparkleInfo.plist` — Sparkle Info.plist keys (merged at build time).
- `paste.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` — pins Sparkle version; commit with the project.
