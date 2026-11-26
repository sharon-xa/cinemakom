<p align="center">
  <img src="branding/app-icon.svg" width="96" alt="Cinemakom logo">
</p>

<h1 align="center">Cinemakom</h1>

<p align="center">
  An alternative app for <a href="https://cinemana.shabakaty.com">Cinemana</a>: movies, series and anime on Android phones, Android TV, Linux and Windows.<br>
  English and Arabic (full right-to-left layout).
</p>

<p align="center">
  <a href="https://github.com/sharon-xa/cinemakom/releases/latest"><img src="https://img.shields.io/github/v/release/sharon-xa/cinemakom?label=download" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/sharon-xa/cinemakom" alt="MIT licence"></a>
</p>

> Cinemakom is an unofficial, independent client. It isn't affiliated with or endorsed by Shabakaty or Cinemana. It has no server of its own: it talks to Cinemana's public API directly, the same way the official website does.

## Screenshots

**Phone**

<table>
  <tr>
    <td width="33%"><img src="docs/screenshots/phone-home.webp" alt="Home on a phone"></td>
    <td width="33%"><img src="docs/screenshots/phone-details.webp" alt="A series on a phone, with seasons, episodes and download buttons"></td>
    <td width="33%"><img src="docs/screenshots/phone-home-ar.webp" alt="Home on a phone in Arabic, right to left"></td>
  </tr>
  <tr>
    <td align="center">Home</td>
    <td align="center">A series</td>
    <td align="center">In Arabic</td>
  </tr>
</table>

**Desktop**

<table>
  <tr>
    <td width="50%"><img src="docs/screenshots/desktop-home.webp" alt="Home on the desktop, with the navigation rail"></td>
    <td width="50%"><img src="docs/screenshots/desktop-player.webp" alt="The desktop player, paused, with Arabic subtitles and subtitle, quality and speed chips"></td>
  </tr>
  <tr>
    <td align="center">Home</td>
    <td align="center">Player</td>
  </tr>
</table>

**Android TV**

<table>
  <tr>
    <td width="33%"><img src="docs/screenshots/tv-home.webp" alt="Home on Android TV, with tabs across the top"></td>
    <td width="33%"><img src="docs/screenshots/tv-details.webp" alt="A series on Android TV, with seasons, episodes and download buttons"></td>
    <td width="33%"><img src="docs/screenshots/tv-player.webp" alt="The TV player with its controls, driven by the remote"></td>
  </tr>
  <tr>
    <td align="center">Home</td>
    <td align="center">A series</td>
    <td align="center">Player</td>
  </tr>
</table>

---

## Features

**Browsing**
- Home with a featured carousel, curated collections, latest movies and series, most watched, new releases and a row for each genre.
- Genre pages that scroll forever, with sorting (recently added, release date, most watched, A→Z) and filters for movies or series and audio language (Anime = Animation × Japanese, for example).
- Search by title or by actor, director or writer, with recent searches saved on the device.
- Title pages with synopsis, genres, trailer, IMDb or MyAnimeList link, cast and crew, and "More like this". Tap a person to see everything they're credited on.
- Series with season and episode pickers. Very long seasons (One Piece is one season of 1,000+ episodes) are split into blocks of 50.

**Player**
- Every quality the title has, up to 4K, with a default you pick in Settings.
- Arabic and English subtitles with size and sync controls. Anime also gets the styled Arabic track on desktop.
- Resume where you stopped, Skip intro, Next episode with an "Up next" countdown, and seek-bar previews.
- Speed and fit modes. Brightness and volume swipes and double-tap seek on phones. Keyboard and mouse on desktop (see [shortcuts](#desktop-player-shortcuts)).

**Library and downloads**
- Continue watching and Favorites, kept on the device. No account needed.
- Download movies, episodes or a whole season with their subtitles. You choose the quality each time and see the file sizes. Downloads can be paused and resumed and play offline.

**Android TV**
- A separate interface built for the remote (D-pad, OK, Back), with tabs across the top. Every action can be reached and the focus never gets stuck.

## Platforms

| Platform | Status |
|---|---|
| Android phones and tablets | ✅ Tested on a real phone (120 Hz, 4K playback) |
| Android TV / Google TV | ✅ Tested on a TCL Google TV. Uses the same APK as phones |
| Linux (x64) | ✅ Tested |
| Windows (x64) | ✅ Tested on Windows 11 (4K playback, downloads, installer and portable zip) |
| iOS, iPadOS, macOS, tvOS | ❌ Not supported |

## Install

Download the file for your device from the [latest release](https://github.com/sharon-xa/cinemakom/releases/latest). `SHA256SUMS.txt` holds the checksums.

### Android phone or tablet
Install `cinemakom-<version>-android-arm64-v8a.apk`. Use `armeabi-v7a` on an old 32-bit phone. Android will ask you to allow installing apps from your browser or file manager.

### Android TV
Most TVs need `armeabi-v7a`: many run a 32-bit system even on a 64-bit chip. If that APK won't install, try `arm64-v8a`. To sideload it:
- with a sideloading app on the TV (such as *Downloader*) and the APK's download link, or
- from a computer with `adb`: turn on wireless debugging on the TV, then
  ```bash
  adb connect <tv-ip>:<port>
  adb install -r cinemakom-<version>-android-armeabi-v7a.apk
  ```

Cinemakom appears in the TV's app list and opens in the TV interface.

> **Upgrading from v1.0.0:** v1.0.0 was signed with a temporary key, so Android won't install newer versions over it. Uninstall it once, then install the new APK. From then on, each update installs over the last and keeps your library and downloads.

### Linux
Install it for your user (no `sudo`):
```bash
curl -fsSL https://github.com/sharon-xa/cinemakom/releases/latest/download/install.sh | bash
```
Cinemakom then shows up in your app menu, or run `cinemakom`. Run the same command again to update. To remove it: `curl -fsSL https://github.com/sharon-xa/cinemakom/releases/latest/download/install.sh | bash -s -- --uninstall` (your library and downloads stay).

Or download `cinemakom-<version>-linux-x64.AppImage`, make it executable and run it: `chmod +x cinemakom-*.AppImage && ./cinemakom-*.AppImage`. AppImage managers such as [Gear Lever](https://flathub.org/apps/it.mijorus.gearlever) and AppImageLauncher can update it, downloading only what changed.

It runs on any 64-bit distro from 2022 on (glibc 2.35, such as Ubuntu 22.04, Debian 12, Fedora, Arch) and brings everything the player needs, so there's nothing else to install.

### Windows
Run `cinemakom-<version>-windows-x64-setup.exe`. It installs for your user, with no admin rights, and adds Cinemakom to the Start menu. To update, run the next version's installer: it installs over the last one and keeps your library. To remove it, use Settings → Apps → Installed apps. It asks before deleting your library, and never deletes your downloaded videos.

Or extract `cinemakom-<version>-windows-x64.zip` and run `cinemakom.exe`. Everything it needs, libmpv included, is in the folder.

The installer isn't signed, so the first time it runs, Windows SmartScreen says "Windows protected your PC". Click **More info**, then **Run anyway**. It has been tested on Windows 11. Please report anything that doesn't work (Settings → Help → Report a bug, or [open an issue](https://github.com/sharon-xa/cinemakom/issues)).

## Desktop player shortcuts

| Key | Action |
|---|---|
| Space, K | Play / pause |
| ← / → | Back / forward 10 s |
| Shift + ← / → | Back / forward 60 s |
| ↑ / ↓ | Volume ±5 |
| M | Mute |
| F, double-click | Full screen |
| Esc | Leave full screen, else close a menu, else leave the player |
| S | Skip intro |
| N | Next episode |
| C | Next subtitle choice |
| [ / ] | Slower / faster |
| 0–9 | Jump to 0–90% |

The mouse wheel changes the volume, and clicking the video plays or pauses it. The seek bar runs left to right in Arabic too.

## What Cinemakom doesn't do

These are deliberate choices:
- **No ratings.** No star or IMDb scores, age ratings, likes or "Top rated" lists.
- **No censorship.** Nothing is filtered, blurred or skipped, and there are no parental controls.
- **No account features.** Anything that needs a Shabakaty login (server-side history, likes, comments) is out of scope. Your library lives on your device.
- **No tracking.** The app never calls Cinemana's telemetry, ad or IP-check hosts. The only outside request it makes is to the public status page, and only after the API fails, so it can tell you when Cinemana itself is down.
- **No import from the old Cinematy app.** It's a new app with a new database.

---

## Building from source

### Requirements
- [fvm](https://fvm.app). The project is pinned to **Flutter 3.47.9** (Dart 3.13) in `.fvmrc`, so always run `fvm flutter`, not `flutter`. Newer Flutter versions draw a quarter of the window on Linux with NVIDIA's driver ([flutter#195885](https://github.com/flutter/flutter/issues/195885)).
- **Linux:** `clang cmake ninja-build pkg-config`, GTK 3 headers and libmpv (on Debian/Ubuntu: `libgtk-3-dev libmpv-dev`). Building the AppImage needs only Docker.
- **Android:** the Android SDK and JDK 17 or newer.
- **Windows:** Visual Studio 2022 with the "Desktop development with C++" workload.

### Run
```bash
fvm install                  # installs the pinned Flutter
fvm flutter pub get          # also generates the localization classes
fvm flutter run -d linux     # the quickest way to see the app
fvm flutter run -d linux --dart-define=CINEMAKOM_TV=true   # the TV interface in a 960×540 window: arrows, Enter = OK, Esc = Back
fvm flutter run -d <android-device-id>                     # `fvm flutter devices` lists them
```
The Android emulator shows no video at all, so test playback on a real device.

### Check
```bash
fvm flutter analyze          # must be clean
fvm flutter test             # unit and widget tests (no network)
fvm dart run tool/api_contract_check.dart   # does the live API still behave as docs/API.md says?
```
The `integration_test/` folder has live end-to-end tests (the player, downloads, the TV interface, screenshots and frame-time checks on a device). [`AGENTS.md`](AGENTS.md#commands) lists how to run each one.

### Release builds
```bash
fvm flutter build apk --release --split-per-abi   # APKs in build/app/outputs/flutter-apk/
tool/build_all.sh                                  # Android APKs and the Linux AppImage into dist/<git describe>/
```
Pushing a `v*` tag runs [the release workflow](.github/workflows/release.yml): it runs analyze and tests, then builds Android, Linux and Windows and publishes a GitHub release. Release APKs are signed with one permanent key. Locally, `android/key.properties` (gitignored) points to it. Without that file, a local build falls back to the debug key, which can't install over an official release.

## How it's built

Flutter, with [Riverpod](https://riverpod.dev) for state, [go_router](https://pub.dev/packages/go_router), [dio](https://pub.dev/packages/dio), [drift](https://drift.simonbinder.eu) (SQLite) and [background_downloader](https://pub.dev/packages/background_downloader). Video plays through **ExoPlayer** on Android (mpv stuttered on 4K there) and **[media_kit](https://github.com/media-kit/media-kit) (mpv)** on desktop, both behind one `PlayerEngine` interface.

```
lib/
  app/        shell, routing, theme, shared widgets, translations (ARB)
  core/       network (the only place that builds URLs and headers), storage, player engines, downloads, platform
  data/       models, tolerant JSON parsers, paging, repositories
  features/   phone, tablet and desktop screens: home, search, details, player, library, downloads, settings…
  tv/         the separate Android TV interface (focus system, screens, player)
test/         unit and widget tests, with fixtures captured from the real API
integration_test/   live end-to-end, screenshot and performance tests
tool/         API contract check, fixture capture, logo and icon generator, release build script
```

The API is undocumented and its JSON is inconsistent (the same field comes under different names), so parsing is hand-written and skips bad items instead of failing.

## Documentation

| File | What's in it |
|---|---|
| [`AGENTS.md`](AGENTS.md) | Rules for contributors (human or AI). **Read it first** |
| [`docs/API.md`](docs/API.md) | The reverse-engineered Cinemana API: endpoints, headers, parameters, limits, quirks |
| [`docs/DESIGN.md`](docs/DESIGN.md) | The "Marquee" design system: colours, type, components, screen layouts, logo |
| [`docs/PLAN.md`](docs/PLAN.md) | Architecture, the feature list and what's done |
| [`docs/PLAYER.md`](docs/PLAYER.md) | The player: architecture, features, measurements |
| [`docs/TV.md`](docs/TV.md) | The Android TV interface and its focus rules |
| [`docs/DOWNLOADS.md`](docs/DOWNLOADS.md) | How downloads stay reliable (pause, resume, expired links, recovery) |

## Contributing

Bug reports and pull requests are welcome. Before you send code:
- read [`AGENTS.md`](AGENTS.md) and the doc for the area you're changing,
- make `fvm flutter analyze` and `fvm flutter test` pass,
- put every new string in both `lib/app/l10n/app_en.arb` and `app_ar.arb`, and check the screen in Arabic (RTL),
- keep to the product rules above (no ratings, no censorship, no login features).

To report a bug, the easiest way is **Settings → Help → Report a bug** in the app: it fills in the app version and your device for you, by email or as a GitHub issue. Say which title you were watching.

## Licence

Cinemakom is released under the [MIT licence](LICENSE). The bundled fonts (IBM Plex Sans, IBM Plex Sans Arabic, Big Shoulders Display and Reem Kufi) are under the SIL Open Font License; their licences are in [`assets/fonts/licenses/`](assets/fonts/licenses). Posters, artwork and videos shown in the app and in the screenshots belong to their owners and come from Cinemana.
