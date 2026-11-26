# Packaging for Linux and Windows

The plan for shipping Cinemakom on desktop (2026-11-24): where the app keeps
its files, which packages to make, and in what order. Android is an APK and
isn't covered here. PLAN.md Phase 8 ("Packaging") points to this file.

Milestones are P0–P2 (§5). Decisions for the owner are in §6.

---

## 1. Where the app keeps its files today

Checked on 2026-11-24 in the packages' sources and on the development
machine (Arch, `/tmp` on tmpfs). The app ID is `io.github.sharon_xa.cinemakom`.
On Windows, path_provider names folders `io.github.sharon_xa\Cinemakom`
(CompanyName and ProductName in `windows/runner/Runner.rc`).

| What | Linux now | Windows now | Problem |
|---|---|---|---|
| Library database (`cinemakom.sqlite`: history, favorites, downloads list) | `~/Documents/` | `Documents\` | drift_flutter's default is `getApplicationDocumentsDirectory`. It's the user's own folder, and it's often synced to OneDrive on Windows |
| Image cache (posters) | `/tmp/libCachedImageData` | `%TEMP%` | flutter_cache_manager's default. On tmpfs it uses RAM and is gone at every reboot, while its index (in the data folder) still lists the files |
| Settings (`shared_preferences.json`) | `~/.local/share/<id>/` | `%APPDATA%\…` (Roaming) | Fine. XDG's place for settings is `~/.config`, but moving them needs a custom store (§6) |
| Download engine state, kept resume data | `~/.local/share/<id>/` | Roaming | Fine on Linux. On Windows it belongs in Local: it's machine-specific |
| Activity log (`logs/`) | `~/.local/share/<id>/logs` | Roaming | XDG puts logs in `$XDG_STATE_HOME` (`~/.local/state`). Windows: Local |
| Subtitle fonts (`libass-fonts/`, copied from assets) | data folder | Roaming | Can be rebuilt any time: belongs in the cache |
| Default download folder | `~/Videos/Cinemakom`, hard-coded | `%USERPROFILE%\Videos\Cinemakom` | Linux ignores `XDG_VIDEOS_DIR`, which is translated on many systems (`~/Vidéos`, `~/الفيديو`) or moved. Windows ignores the Videos known folder, which users move to OneDrive or another drive |
| Unfinished downloads | `<download folder>/.partial` | same | Hidden on Linux. On Windows a dot doesn't hide it, so the folder shows up in Videos |
| Activity log export | temp folder | temp folder | Fine |

The machine also has a stale `~/.local/share/<id>/fonts/` from an early
build.

### Should we follow XDG? Yes

- **Users expect it.** Backups and dotfile sync cover `~/.local/share` and
  `~/.config`. Cleaners empty `~/.cache` and `/tmp`. An app that drops a
  database in `~/Documents` looks broken or rude.
- **Windows has the same split:** Roaming for small settings, Local for
  machine-specific data and caches, the Videos known folder for videos.

## 2. P0: put every file in the right place (before any package)

*Built 2026-11-24. Checked on Linux (2026-11-24) on the owner's real
library, and on Windows 11 Pro (2026-11-25/26): old libraries moved out of
Documents (with history and favorites intact and schema upgraded), logs
moved to the state folder, posters fill the cache folder, relocated
Windows Videos known folders resolve, `.partial` is hidden on Windows,
legacy files are cleaned up, and a second launch hands over to the open
window.*

`AppDirs` (`lib/core/platform/app_dirs.dart`) decides the app's own
folders on desktop, once, before `runApp`. On Android and in tests
`AppDirs.current` is `null` and every file stays where it always was
(moving Android's database would lose people's libraries).

| Folder | Linux | Windows | Android |
|---|---|---|---|
| data (library database) | `$XDG_DATA_HOME/<id>` (`~/.local/share/…`) | `%LOCALAPPDATA%\io.github.sharon_xa\Cinemakom` | unchanged |
| cache (posters, subtitle font) | `$XDG_CACHE_HOME/<id>` (`~/.cache/…`) | `…\Cinemakom\cache` (Local) | unchanged |
| state (`logs/`) | `$XDG_STATE_HOME/<id>` (`~/.local/state/…`) | `…\Cinemakom\logs` (Local) | unchanged (external folder, for `adb pull`) |
| default downloads | `XDG_VIDEOS_DIR/Cinemakom` | Videos known folder `\Cinemakom` | unchanged |
| settings, download engine state | `~/.local/share/<id>` (the packages' own choice) | Roaming AppData (the packages' own choice) | unchanged |

The last row can't move: shared_preferences and background_downloader
pick the app support folder themselves. On Linux that's already the XDG
data folder. On Windows it's Roaming, which works; it only matters on
company networks that sync Roaming between PCs.

XDG rules followed (and unit-tested, `test/core/platform/app_dirs_test.dart`):
an unset, empty or relative variable falls back to the default; the
videos folder comes from `user-dirs.dirs` (`$HOME/…`, translated names,
absolute paths), else `XDG_VIDEOS_DIR`, else `~/Videos`; a value of just
`$HOME` means the folder is turned off.

What changed:
- **Database:** `appDatabaseDirectory` (`lib/core/storage/legacy_files.dart`)
  is drift's `databaseDirectory`. On desktop it first moves an old
  `cinemakom.sqlite` (and any `-journal`, `-wal`, `-shm`) from Documents:
  copied first, switched into place when every copy is written (the
  database last), and the old files deleted only then. A library already
  in the new folder is never overwritten; a failed copy keeps the old
  files and is logged. A start that stops halfway finishes on the next.
- **Posters:** one cache, `appImageCache` (`lib/core/storage/image_cache.dart`),
  for `MediaImage`, `TvImage` and the seek preview, files and index in
  `<cache>/images`.
- **Logs:** `logDirectory()` uses `<state>/logs`; the old log moves there
  before the log opens its file, so the last session's survives.
- **Subtitle font:** `<cache>/subtitle-fonts`.
- **Downloads:** `defaultDesktopFolder()` uses the videos folder. A folder
  picked in Settings is kept. On Windows the `.partial` folder gets the
  hidden attribute.
- **Cleanup, in the background:** the old `libass-fonts/` and `fonts/`
  (only if it holds nothing but fonts), the old cache index and the old
  poster files in the temp folder.
- **One instance, in release builds:** Linux is a unique `GApplication`
  (a second launch presents the open window); Windows takes a named mutex
  and brings the open window forward. Debug builds stay non-unique, so
  `flutter run` and the integration tests start while the installed app
  is open.

### 2.1 Windows P0 check ✅ *(verified 2026-11-25/26 on Windows 11 Pro 25H2)*

Checked on a local Release build (`cinemakom.exe` 2.0.0):
1. **Old v1.0.x library migration:** seeded a schema v2
   `Documents\cinemakom.sqlite` with `watch_history` and `favorites` rows;
   on launch `cinemakom.exe` moved it to
   `%LOCALAPPDATA%\io.github.sharon_xa\Cinemakom\cinemakom.sqlite`,
   upgraded schema v2 → v4 with all rows intact, removed the old file from
   `Documents\`, and logged `folders: data …` and
   `moved the library from …` in `logs\current.log`. Stale companion files
   from an interrupted migration are also cleaned before staging
   (`test/core/storage/legacy_files_test.dart`).
2. **Moved `Videos` known folder & hidden `.partial`:** redirected
   Windows `FOLDERID_Videos` (`My Video`) to a folder with spaces;
   `cinemakom.exe` resolved it cleanly in `logs\current.log` (and a failed
   `FOLDERID_Videos` lookup falls back to `%USERPROFILE%\Videos` without
   disabling `AppDirs`). Verified `platformPartialDir` sets the Windows
   `Hidden` attribute on `.partial`, including paths with spaces and Arabic
   names (`test/data/download_paths_test.dart`).
3. **One instance & legacy cleanup:** verified single-instance handoff via
   `CINEMAKOM_WIN32_WINDOW` (2nd launch exits 0 with 1 process running) and
   removal of legacy cache/font files.

## 3. Linux

### What limits a plain binary (checked 2026-11-24)
- **libmpv 2 is a hard dependency.** `libmedia_kit_video_plugin.so` links
  `libmpv.so.2`, so a plain build doesn't start on systems that only have
  libmpv 1 (Ubuntu 22.04, Debian 11).
- **glibc:** a binary needs a glibc at least as new as the one on the
  machine that built it. The development machine has glibc 2.44, and CI's
  `ubuntu-latest` moves to new Ubuntu versions by itself. So the AppImage
  is built in an Ubuntu 22.04 container (glibc 2.35).
- GTK 3 comes from the user's system. It's on every Linux desktop, and the
  system's copy brings its themes, input methods (Arabic keyboards) and
  Wayland support.

### What we ship and what comes from the system
Bundling the player's libraries makes the app work the same everywhere,
but their security fixes become ours. FFmpeg parses whatever file the CDN
sends. A distro patches its own copy; ours stays as old as our last
release. So:

- **In the AppImage:** FFmpeg 8.1.3, libmpv (mpv 0.42.0), libass 0.17.5,
  libplacebo 7.387.0 and libva 2.24.1, all built from release archives
  pinned by checksum (`linux/appimage/Dockerfile`). On Windows: libmpv with
  its FFmpeg. **Rule: a security release of any of them means a Cinemakom
  release.** Later, a scheduled CI job can compare our versions with the
  latest and warn us.
- **From the user's system**, the list in `linux/appimage/bundle_libs.py`
  (`SYSTEM`):
  - glibc and the compiler runtime.
  - GTK 3 and what it's built on (GLib, Pango, Cairo, HarfBuzz, FreeType,
    Fontconfig, FriBidi, X11).
  - The GPU's libraries: libGL, EGL, libdrm and the VA-API drivers. They
    must match the kernel and the GPU (Mesa or NVIDIA).
  - **GnuTLS** (FFmpeg's TLS for every stream), PulseAudio's client
    library and ALSA. Their security fixes reach us with system updates.
    Not OpenSSL: Fedora 45 moved to OpenSSL 4, and a library linked to
    OpenSSL 3 didn't load there (found in testing). GnuTLS's library name
    hasn't changed since 2015, and even the bare Ubuntu, Debian, Fedora
    and Arch container images have it.
  - **libGLESv2**, which the Flutter engine loads: desktops have it. A
    minimal Debian or Ubuntu without a desktop needs `libgles2`.

  Every desktop Linux with GTK 3 from 2022 on has these. The build stops
  if anything else is needed and isn't ours, so nothing joins the AppImage,
  or is left out of it, without a decision in that file.
- **libva: the system's, or ours when the system's is older or missing.**
  A VA-API driver opens only with a libva at least as new as the one it
  was built for. A driver built for a newer libva is skipped, and video
  quietly decodes on the CPU. We tested this with a driver faked to need
  1.25 (2026-11-25). Distros build Mesa's drivers against their own
  libva (Arch's Mesa wants 1.24).
  - **Ours** (2.24.1) is for systems whose libva is older (Ubuntu 22.04
    has 2.14, Debian 12 has 2.17, Ubuntu 24.04 has 2.20) or that have none.
    It looks for the system's drivers in the Debian/Ubuntu, Fedora/openSUSE,
    Arch and NixOS folders.
  - **The system's** is used when it's at least as new as ours, so a distro
    that updates libva and Mesa together keeps working without a new
    Cinemakom.
  - **How:** ours is in `lib/libva/`, which nothing searches. `AppRun`
    compares the versions in the two files' names (`libva.so.2.2400.0` is
    1.24), and adds that folder to `LD_LIBRARY_PATH` only when ours is
    needed. Every launch goes through `AppRun`: the installed app, the
    menu entry and `~/.local/bin/cinemakom` all point to it.
  - **Checked 2026-11-25:** Ubuntu 22.04 with and without libva, Ubuntu
    24.04 and Debian 12 load ours. Fedora 45 and Arch (2.24) load the
    system's, and so does a faked newer system libva (2.25).
- **Licenses:** mpv is GPL (2 or later), and FFmpeg and libplacebo are
  LGPL. The app is MIT, which is compatible: together they're distributed
  under the GPL. The AppImage carries every license
  text in `usr/share/licenses/`.
  - **Corresponding source (Linux, 2026-11-25):** each build writes
    `cinemakom-<version>-linux-x64-sources.tar` next to the AppImage, and
    the release publishes it with the AppImage. It holds the exact archives
    the image built from (`fetch` keeps them in `/opt/sources`, checked by
    SHA-256), and libplacebo's tag with its submodules. It also has the
    build scripts (`build/`) and a README.
  - **Corresponding source (Windows, 2026-11-25):** the release publishes
    `cinemakom-<version>-windows-x64-sources.tar.zst` (§4, "libmpv's
    source").

### Format: AppImage only (decision 2026-11-24)

There is one Linux package (the owner's decision), so there's one thing to keep working.

**Why not Flatpak (dropped the same day, after it was built):**
- **Flathub won't take the app.** Its policy (read 2026-11-24): manifests
  must not be AI-written; an AI-generated app may be rejected without
  review; and AI tools must not open or write submissions. Flathub also
  requires apps built from source offline, and rarely takes new projects.
- **Without Flathub, the Flatpak's advantages go.** A downloaded `.flatpak`
  doesn't update itself. And a first install pulls in the GNOME runtime,
  1.1 GB installed, plus about 460 MB of graphics drivers. That's a lot to
  ask before the app even starts, especially on a slow or metered
  connection. The manifest is in git history (commit dbc43ad).

**The AppImage:** one file with everything the player needs: 24 MB.
- **Runs straight away:** `chmod +x` and run. It uses the static AppImage
  runtime, which needs FUSE but not the old libfuse2 that newer distros
  dropped. Without FUSE, `--appimage-extract-and-run` works.
- **Or install it:** `install.sh`, attached to each release:
  `curl -fsSL …/releases/latest/download/install.sh | bash`. It works per
  user, with no sudo:
  - It downloads the release's AppImage and checks it against the
    release's `SHA256SUMS.txt`.
  - It unpacks it into `~/.local/lib/cinemakom`, so the installed app runs
    without FUSE and starts without mounting anything.
  - It adds `~/.local/bin/cinemakom`, and a menu entry with the icons in
    `~/.local/share`.
  - **Updates:** run the script again. It finds the latest release through
    GitHub's `/releases/latest` redirect (no API token), and swaps the
    folder only once the new one is complete.
  - `--version`, `--file` and `--uninstall` are the other options.
    Uninstalling keeps the library and downloads, and says where they are.
- **Or let an AppImage manager update it** (decision 2026-11-25): the
  AppImage carries update information,
  `gh-releases-zsync|sharon-xa|cinemakom|latest|cinemakom-*-linux-x64.AppImage.zsync`,
  in its runtime's `.upd_info` section (`build.sh` writes it, as
  appimagetool does). AppImageUpdate, Gear Lever and AppImageLauncher read
  it, take the `.zsync` file from the latest release (published next to
  the AppImage), and download only the blocks that changed.
  - **"Latest"** is GitHub's latest release, so prereleases (`v1.2.0-rc1`)
    are never offered.
  - **The `.zsync` is made from the final file**, after the update
    information is written. Its URL is just the file's name, so it's
    relative to the release it's in.
  - The copy `install.sh` unpacks isn't an AppImage, so these tools don't
    see it: running `install.sh` again still updates it.
- **Files:** plain XDG (§2), with no sandbox and no `~/.var/app`.
- **Build:** `tool/build_appimage.sh` (Docker), locally and in the release
  workflow:
  1. The image `linux/appimage/Dockerfile` (Ubuntu 22.04) builds the
     libraries into `/opt/deps`, and holds Flutter 3.47.9.
  2. `linux/appimage/build.sh` copies the source into the container, runs
     `flutter build linux --release` and assembles the AppDir. The
     source's own `build/` isn't touched.
  3. `bundle_libs.py` adds our libraries (libva apart, in `lib/libva`),
     makes them find each other (RUNPATH `$ORIGIN`), and stops on anything
     undecided.
  4. The squashfs (zstd) is appended to the pinned type2 runtime. That
     runtime is only published as "continuous": when its checksum stops
     matching, look at what changed upstream before taking the new one.

  CI caches the image's layers, so FFmpeg and mpv only rebuild when the
  Dockerfile changes. The first local run takes about 15 minutes.
- **The player inside:**
  - libmpv draws through the OpenGL context the app gives it (`plain-gl`).
    It has no X11 or Wayland code: mpv 0.42's Wayland code needs
    libwayland 1.23, and Ubuntu 22.04 has 1.20.
  - **Hardware decoding:** NVIDIA decodes on the GPU and hands frames to
    OpenGL without copies (CUDA; driver 530 or newer). Intel and AMD use
    VA-API with copy-back (`vaapi-copy`): the GPU decodes, and each frame
    passes through memory once. That's fine up to 4K on recent hardware.
    Without either, mpv decodes in software (`hwdec=auto`).
  - **Only our libmpv may load.** media_kit opens `libmpv.so` by name,
    and where mpv is installed that's the system's copy, while the video
    plugin is linked to ours. Two libmpv in one process abort as a video
    opens (it crashed on this machine, which has mpv). So `initMediaKit`
    (`media_kit_engine.dart`) passes the `lib/libmpv.so.2` next to the
    app. The container tests couldn't catch it: none had mpv installed.
  - **That wasn't enough (v2.0.0, issue #6).** As each video opens,
    media_kit_video's `queryDecoders` calls
    `NativeLibrary.ensureInitialized()` with no path. That resets the path
    media_kit uses to its default lookup, `libmpv.so` first, which is the
    system's again. It then calls the system's `mpv_get_property` with a
    handle from ours. With mpv 0.42 on this machine (the same version as
    ours) that went unnoticed. With Arch's 0.41 it segfaulted. So now:
    - `bundle_libs.py` adds `lib/libmpv.so → libmpv.so.2`. The lookup runs
      in the engine (`libflutter_linux_gtk.so`, RUNPATH `$ORIGIN`), so it
      finds the link before `/usr/lib` and gets the library that's already
      loaded. This works however the app is started.
    - AppRun exports `LIBMPV_LIBRARY_PATH`, which media_kit's lookup reads
      before any name. It wins over an `LD_LIBRARY_PATH` that lists the
      system's libmpv, and over the user's own `LIBMPV_LIBRARY_PATH`.
    - To check: play a video. `/proc/<pid>/maps` must list only
      `usr/lib/cinemakom/lib/libmpv.so.2`.

*Checked 2026-11-24:*
- **Clean containers:** Ubuntu 22.04, Debian 12, Fedora 45 and Arch, with
  only GTK 3, Mesa and sound libraries installed. Every library resolves.
  The bundled libmpv plays H.264 with AAC, and HEVC, to the end, and opens
  HTTPS through the system's GnuTLS. The app starts (Xvfb), stays up, and
  writes its log in the XDG folders. On 2026-11-25 Ubuntu 24.04 passed
  too, with the libva choice above.
- **This machine** (EndeavourOS, Wayland, NVIDIA): the AppImage runs
  through FUSE with the real library, and a second launch hands over to
  the open window. HEVC decodes on the GPU (`nvdec-copy` in the test;
  without the copy in the app).
- **`install.sh`:** install, reinstall and uninstall in a clean Ubuntu
  container; a release without an AppImage gives a clear error.
- **Left:**
  - The release workflow's Linux job has never run.
  - Playback of a real stream through the UI.
  - A try on a real Ubuntu or Fedora desktop (GNOME, KDE), and VA-API on
    Intel or AMD.

**Not offered:** Flatpak or Flathub (above), AUR, `.deb`, `.rpm`, Snap.

### Desktop integration (what makes it feel native)
- Done: desktop file with an Arabic name, `StartupWMClass` matching the app
  ID, icons at every size plus SVG.
- Done in P0: one instance (a second launch brings the open window to the
  front instead of running a second download engine on the same library).
- **Metainfo** `linux/packaging/io.github.sharon_xa.cinemakom.metainfo.xml`,
  inside the AppImage: English and Arabic, screenshots and releases, for
  AppImage catalogues. `appstreamcli validate` passes. Its OARS content
  declaration (required, empty) describes the app for a store; it isn't a
  ratings feature.
- **To check on GNOME and KDE, Wayland and X11:** full screen in the
  player, fractional scaling, the screen staying on during playback, and
  hardware decoding (VA-API) with Intel, AMD and NVIDIA.

## 4. Windows

### What's built (2026-11-25)
- **Visual C++ runtime DLLs bundled:** `windows/CMakeLists.txt` uses
  `InstallRequiredSystemLibraries` so `msvcp140.dll` (and companions),
  `vcruntime140.dll`, `vcruntime140_1.dll` and `concrt140.dll` ship next to
  `cinemakom.exe` in Profile and Release builds (both the installer and the
  portable zip).
- **Current `libmpv-2.dll` pinned by SHA256:** `windows/CMakeLists.txt`
  replaces `media_kit_libs_windows_video`'s 2023-09-24 DLL with
  `shinchiro/mpv-winbuild-cmake` `mpv-dev-x86_64-20261111-git-bcde6b93cc.7z`,
  verified against its SHA256 checksum (depends only on built-in Windows
  DLLs and the bundled `vulkan-1.dll`). Follow the §3 rule: an FFmpeg or
  mpv security release means bumping this pin and shipping a Cinemakom
  release.
- **Inno Setup installer (`windows/packaging/cinemakom.iss`):** per user
  (`%LOCALAPPDATA%\Programs\Cinemakom`, no admin rights), fixed `AppId`
  (`io.github.sharon_xa.cinemakom`), Windows Restart Manager
  (`CloseApplications=yes`) so a running instance closes cleanly on upgrade
  or uninstall (including silent upgrades), Start menu +
  optional desktop shortcut, Installed apps entry, English and Arabic setup
  screens (Inno Setup 6.5+, UTF-8 BOM), and an uninstall prompt that asks
  before removing the library/settings (including any legacy
  `Documents\cinemakom.sqlite*`) and never deletes downloaded videos.
- **Windows runner hardening:** unique window class
  (`CINEMAKOM_WIN32_WINDOW`) so single-instance handoff works in Arabic as
  well as English; pins `LIBMPV_LIBRARY_PATH` to the bundled `libmpv-2.dll`
  beside `cinemakom.exe` so an external `LIBMPV_LIBRARY_PATH` never loads a
  second `libmpv` into the process; dark title bar matching Marquee even in
  Windows Light Mode; high-DPI work-area clamping and centering on startup;
  3 s shutdown watchdog on `OnDestroy` so a hung plugin or DLL detach never
  leaves a windowless zombie process holding the single-instance mutex; and
  deferred fullscreen exit when leaving the player mid-frame.
- **Local & CI build:** `tool/build_windows_installer.ps1` builds the
  release, portable zip and Setup `.exe` into `dist/`. The `windows` job in
  `.github/workflows/release.yml` verifies the bundled DLLs, packages both
  the zip and Setup `.exe`, and runs a silent install → launch → uninstall
  smoke test.

*Checked on Windows 11 Pro 25H2 (2026-11-25/26):*
- `fvm flutter analyze` clean and full `fvm flutter test` passing.
- `integration_test/player_engine_test.dart -d windows` and
  `integration_test/player_test.dart -d windows` passing on the 2026-11-11
  `libmpv-2.dll`: 1080p → 720p switch, 4K playback 19.4 s in 20.1 s
  (`d3d11va` zero-copy at `23.976 fps` with 0 dropped frames), WASAPI audio,
  plain and `libass` styled Arabic subtitles via DirectWrite, disk cache in
  `<cache>/mpv-cache` with 0 `lavf` errors.
- `integration_test/downloads_test.dart -d windows` and
  `integration_test/downloads_recovery_test.dart -d windows` passing (live
  CDN download, pause, resume, offline play, recovery, delete).
- `LIBMPV_LIBRARY_PATH` isolation: launching `cinemakom.exe` with
  `LIBMPV_LIBRARY_PATH` set to an external DLL loads only the bundled
  `libmpv-2.dll`.
- Installer & portable zip lifecycle: fresh install (files, Start menu
  shortcut, Installed apps entry, English + Arabic `Arabic.isl`), launch
  (`Cinemakom 2.0.0 (2)` in log), portable zip extraction & launch,
  single-instance handoff (`CINEMAKOM_WIN32_WINDOW`), `AppDirs` folders and
  Activity log in `%LOCALAPPDATA%\io.github.sharon_xa\Cinemakom`, v1.0.x
  `Documents\cinemakom.sqlite` migration (v2 → v4), moved `Videos` known
  folder, hidden `.partial`, legacy cache cleanup, live upgrade while the
  app is running (`ExitCode=0`, app closed cleanly), clean `WM_CLOSE` exit
  with 0 lingering processes, and clean silent uninstall.
- PE DLL import audit of every `.exe` and `.dll` in `Release\`: all loaded
  binaries depend exclusively on built-in Windows 10/11 system DLLs plus
  the bundled VC++ runtime (`msvcp140*.dll`, `vcruntime140*.dll`,
  `concrt140.dll`), ANGLE, Vulkan, `libmpv-2.dll`, `sqlite3.dll` and
  `cnativeapi.dll` (`media_kit_video`'s ANGLE `zlib.dll` is unreferenced
  and never loaded).
- CI release run (`v2.0.0`, run `45541632882`, 2026-11-25): `Build Windows
  (x64)` (portable zip, Inno Setup `.exe`, silent install/launch/uninstall
  smoke test) and `Windows libmpv sources` (`…-windows-x64-sources.tar.zst`)
  both passed and published.
- UI pass (`test/features/windows_ui_pass_test.dart`,
  `test/features/player/player_screen_test.dart`): all tabs, Details,
  Activity log and Player render cleanly at 150% DPI (`1280×688`) and 200%
  DPI (`960×516`) in English and Arabic; Arabic keyboard input in Search
  and recent searches works; Windows fullscreen enter/exit/restore works;
  and player keyboard shortcuts also work under an Arabic keyboard layout
  (`_KeyActivator` physical-key fallback).

### Still remaining on Windows
- **libmpv's source (GPL), reconstructed (2026-11-25):** shinchiro's
  mpv-winbuild-cmake publishes only binaries. It builds mpv, FFmpeg and 85
  other packages from their git branches, and records only mpv's commit.
  `windows/packaging/libmpv-sources.lock.json` names the exact source of
  our DLL, worked out by `tool/windows_libmpv_sources.py lock` from the
  recipes (commit `bda10a28`) and the build's public logs:
  - **58 packages: logged.** Every update step prints each branch that
    moved. The logs of the build (run 42927840447, the "mpv clang"
    workflow) and of every run since 2026-08-28 give each branch's last
    move, so its commit is exact.
  - **10 pinned** in the recipes (a commit, or an archive with its hash),
    and **2 named** in the release's file names (mpv, FFmpeg).
  - **16 by date:** branches that never moved in those logs. Each is its
    last commit before 2026-08-28. Every one of them is older than that.
  - **curl, by its version:** the recipes never update curl, so it kept
    whatever an old cache cloned, and no record shows the commit. The DLL
    reports libcurl 8.22.0-DEV, so the archive has curl 8.21.0 and every
    commit after it up to 8.22.0, as patches (the history between them
    is linear).
  - Checked: the date method alone got 2 of 55 wrong (commits pushed later
    with older dates), which is why the logs come first.

  The release job `windows-sources` runs `fetch`. It downloads exactly
  what the lock names (git by commit, with submodules, Rust crates through
  `cargo vendor`, and archives checked by hash), adds the recipes with
  their patches, and packs it. It refuses to run if
  `windows/CMakeLists.txt` ships a different DLL than the lock is for.
  **When the DLL changes, run `lock` again within 90 days of that build**:
  GitHub deletes the logs after that. Or build libmpv ourselves.
- **Unsigned:** Windows SmartScreen warns ("Windows protected your PC")
  the first time a downloaded `.exe` or installer runs.
- **Windows Sandbox live boot:** PE import audit confirmed no missing
  VC++ Redistributable DLLs, but the Windows Sandbox optional feature
  (`Containers-DisposableClientVM`) is not enabled on the dev PC yet; once
  enabled, run a live clean-PC check for first install, update, uninstall
  and portable zip.
- **4K stutter check on weaker Windows 11 hardware (unproven, for later
  review):** slight 4K stutter was reported anecdotally on a less powerful
  Windows 11 PC; not reproducible on an RTX 5070 (`d3d11va`, 0 dropped
  frames, `raster p95 = 0.56 ms`). Suspects to measure on that machine
  (`hwdec-current`, `frame-drop-count`, `decoder-frame-drop-count`) before
  changing any player setting:
  - `media_kit_video`'s Windows ANGLE pipeline (`angle_surface_manager.cc`)
    allocates two full `3840×2160` BGRA8888 textures (~33 MB each) even on
    1080p screens, stalls on `glFinish()`, and copies via `CopyResource`
    every frame (Windows-only; Linux uses zero-copy `EGLImageKHR` +
    `glFlush()`, Android uses ExoPlayer).
  - `media_kit_video`'s `windows/video_output.cc` hardcodes
    `video-timing-offset=0` (commented out on Linux) alongside `framedrop=vo`
    on desktop (`media_kit_engine.dart` only sets `framedrop=no` off
    desktop).
  - `hwdec=auto` falling back to CPU software decoding if zero-copy
    `d3d11va` EGL interop fails on an older iGPU/driver (shared risk with
    Linux).
  - Standard 3:2 pulldown judder for `23.976 fps` content on `60 Hz`
    displays (`video-sync=audio`).

### Formats, in order
1. **An installer (Inno Setup), per user, no admin rights:**
   - Installs in `%LOCALAPPDATA%\Programs\Cinemakom`.
   - Start menu shortcut, and a desktop one if the user wants it.
   - An entry in Installed apps, with an uninstaller.
   - Installs over the last version (a fixed AppId) and closes a running
     Cinemakom first.
   - English and Arabic setup screens.
   - On uninstall, asks before removing the library and settings. Never
     deletes downloaded videos: those belong to the user.
   - Built in the release workflow on `windows-latest`, which installs
     Inno Setup first.
2. **The portable zip, kept**, with the runtime DLLs, for people who don't
   want an installer.
3. **Later:** MSIX and the Microsoft Store (updates, and Microsoft signs
   it). MSIX redirects writes to AppData and limits the file system, so the
   downloads engine and the folder picker need checking there first.

### Testing on Windows
- **CI** (`windows-latest`) runs the tests, plus a smoke test in the
  release workflow: install silently, start the app, check it's still
  running after a few seconds, uninstall. CI runners already have the
  Visual C++ runtime, so CI can't catch a missing DLL.
- **Windows Sandbox on the owner's Windows machine** (Windows 10 and 11
  Pro, virtualization on) is a clean, throwaway Windows: no Visual C++
  runtime, nothing installed. Use it for every installer check: a first
  install, an update over the last version, uninstall, a zip started from
  Downloads, SmartScreen. Closing it erases everything, so each run starts
  clean. On Windows Home, use a Windows 11 evaluation VM on the Linux
  machine (KVM) instead.
- **The owner's Windows machine itself**, on real hardware: playback up to
  4K with hardware decoding, full screen, 150% and 200% scaling, Arabic
  keyboard input, a Videos folder moved to OneDrive or another drive,
  downloads, and the Activity log.

## 5. Milestones

| | What | Done when |
|---|---|---|
| **P0** | Folders (§2), migration, one instance on both OSs | ✅ Linux 2026-11-24; ✅ Windows 2026-11-26 (folders, v1.0.x library move & v2→v4 upgrade, moved Videos folder, hidden `.partial`, legacy cleanup, Activity log, one instance) |
| **P1** | Windows: runtime DLLs, a current libmpv, first real-machine run, Inno installer in CI | Built & checked on Windows 11 Pro 2026-11-25/26 (4K playback, downloads, PE DLL audit, portable zip, installer lifecycle, CI `v2.0.0` release & `windows-sources` run, 150%/200% DPI, fullscreen & Arabic input/shortcuts). Left: live Windows Sandbox clean-PC boot (optional feature not enabled on dev PC) |
| **P2** | Linux: the AppImage and `install.sh` in CI, the tarball dropped, README points to the script | Built and checked (§3). Left: the first CI run, a real stream through the UI, a real Ubuntu or Fedora desktop |

## 6. Decisions for the owner

1. **Settings in `~/.config`:** strict XDG, but it needs our own settings
   file instead of shared_preferences on Linux. Recommendation: not worth
   it now. Every other file moves in P0.
2. **Windows installer:** per user (recommended: no admin, installs over
   itself quietly) or for all users?
