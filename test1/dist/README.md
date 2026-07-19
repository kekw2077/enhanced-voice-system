# EVS — Windows updates (WinSparkle / auto_updater)

This replaces Shorebird (mobile-only, Dart-patches-only) with a real desktop
updater. EVS ships **full installers**, so updates can include native changes
(new plugins, `dart:ffi`, the Python sidecar) — not just Dart code.

## How it works

1. The app embeds the **DSA public key** (`dsa_pub.pem`) via
   `windows/runner/Runner.rc`.
2. On launch (Windows only) `DesktopIntegration.init` calls
   `autoUpdater.setFeedURL(...)` + `setScheduledCheckInterval(6h)`. The
   «Проверить обновления» button in Settings → «О приложении» triggers an
   immediate check (`DesktopIntegration.checkForUpdates`).
3. WinSparkle fetches [`appcast.xml`](appcast.xml), compares `sparkle:version`
   to the installed build, and if newer, downloads the signed installer,
   **verifies its DSA signature** against the embedded public key, and runs it.

Feed URL: `https://raw.githubusercontent.com/kekw2077/enhanced-voice-system/main/test1/dist/appcast.xml`
(defined in `DesktopIntegration.updateFeedUrl`). Override at runtime with the
`EVS_UPDATE_FEED` environment variable — used by the local staging test below
and handy for a self-hosted feed.

## Local staging test (watch an update happen, no publishing)

WinSparkle only offers an update when the feed advertises a **higher**
`sparkle:version` than the installed build. To see the full download+install
flow locally:

```powershell
# 1. Serve a "newer" appcast + the installer from a temp folder.
#    Copy dist/appcast.xml to a staging copy, bump sparkle:version to 1.0.1,
#    point the enclosure url at http://localhost:8000/EVS-Setup-1.0.0.exe, and
#    re-sign is NOT needed (same file, same signature/length).
cd dist\out
python -m http.server 8000        # serves this folder (installer + staging appcast)

# 2. In another shell, launch the INSTALLED EVS pointed at the local feed:
$env:EVS_UPDATE_FEED = "http://localhost:8000/appcast-staging.xml"
& "$env:ProgramFiles\EVS\evs.exe"
# Settings -> О приложении -> «Проверить обновления» -> WinSparkle offers 1.0.1,
# verifies the signature against the embedded key, downloads and runs it.
```

This proves the whole chain (fetch → version compare → DSA verify → download →
install) without touching the production feed.

## Keys

- `dsa_pub.pem` — committed, embedded in the build. Safe to share.
- `dsa_priv.pem` — **git-ignored, secret.** Used only to sign installers.
  **Back it up.** If lost, no existing install can ever upgrade again
  (you'd have to ship a new app with a new key out-of-band).

Regenerate (only if compromised) with Git's openssl:

```powershell
$ssl = "C:\Program Files\Git\usr\bin\openssl.exe"
& $ssl dsaparam -out dsaparam.pem 4096
& $ssl gendsa -out dsa_priv.pem dsaparam.pem
Remove-Item dsaparam.pem
& $ssl dsa -in dsa_priv.pem -pubout -out dsa_pub.pem
```

## Releasing a new version

1. **Bump** `version:` in `pubspec.yaml` (e.g. `1.0.1+2`).
2. **Build** the release:
   ```powershell
   flutter build windows --release
   ```
3. **Make the installer** (needs [Inno Setup 6](https://jrsoftware.org/isdl.php)):
   ```powershell
   iscc dist\installer.iss /DAppVersion=1.0.1
   ```
   → `dist\out\EVS-Setup-1.0.1.exe`
4. **Sign** it and read off the length:
   ```powershell
   .\dist\sign_update.ps1 .\dist\out\EVS-Setup-1.0.1.exe
   ```
5. **Upload** the `.exe` to a GitHub Release (tag e.g. `desktop-v1.0.1`).
6. **Edit** [`appcast.xml`](appcast.xml): add a new `<item>` at the top with the
   real `url`, `length`, `sparkle:version` and `sparkle:dsaSignature`.
7. **Commit** `appcast.xml` on the `desktop` branch. Within ~minutes
   (raw.githubusercontent cache) installed copies will see the update.

> The appcast and installer are hosted on GitHub — no server to run. Hosting
> can move to GitHub Pages/Releases later without app changes (just update
> `updateFeedUrl`).

## Components (sidecar + voice clone) — downloaded on demand

Heavy native pieces are **not** bundled in the installer (which keeps it ~15 MB
and every update small). They live as GitHub release assets, described by
[`components.json`](components.json), and the app downloads + sha256-verifies
them into its data folder (`ComponentManager`).

- **sidecar** (`evs_sidecar.exe`, ~95 MB) — STT (Whisper/GigaAM) / VAD / denoise
  / TTS (Piper + system) / intent. Piper voices are downloaded separately via the
  in-app model manager into `<userdata>/models/`.

To (re)publish the sidecar component:

```powershell
# 1. Build the exe and refresh components.json (sha256 + size):
cd sidecar
.\build_exe.ps1 -ComponentVersion 2          # bump version when the exe changes

# 2. Upload the exe to the components release (create the tag once):
gh release create desktop-components --title "EVS components" --notes "On-demand components" 2>$null
gh release upload desktop-components .\dist\evs_sidecar.exe --clobber

# 3. Commit dist\components.json on the `desktop` branch (the app reads it from
#    raw.githubusercontent, ~5 min cache).
```

The Whisper model itself is fetched by faster-whisper on first use into the
app's data folder (`HF_HOME`), so changing the Whisper size just downloads that
size on demand.
