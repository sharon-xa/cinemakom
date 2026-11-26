# Cinemakom Player: Build Plan (Phase 4)

**The player is the most important part of the app.** This file is the detailed plan for PLAN.md Phase 4, and it replaces that phase's short list. Read it with `docs/API.md` §3 (streams, subtitles, intro ranges, seek previews) and `docs/DESIGN.md` §8 (the player screen).

---

## 1. What "the best player" means here

These are the targets. Every milestone below is checked against them.

| Area | Target |
|---|---|
| **Start** | The first frame appears within 3 s of tapping Play on 1080p over a normal connection, even though 1080p files aren't fast-start (API.md §3). A `BulbLoader` shows while it loads, never a spinner or a black screen |
| **Seeking** | A seek inside the buffer is instant. A seek outside it shows the loader and plays within 2 s |
| **Never stuck** | Every failure ends in a clear message with **Try again**. An infinite loader is a bug. Expired URLs (403) and dropped connections recover by themselves at the same position |
| **Never lose progress** | At most 10 s of progress is lost, whatever happens: app killed, crash, unplugged laptop |
| **Smooth controls** | The controls run at 60 fps on a mid-range Android phone while 1080p plays. Position updates repaint only the seek bar and the clock |
| **Switching keeps your place** | Changing quality, subtitles or episode keeps the position (quality), the subtitle and speed choices (episode), and the play/pause state |
| **Works everywhere** | Touch on Android (remote on Android TV), keyboard and mouse on Linux and Windows, in English (LTR) and Arabic (RTL) |

## 2. Decisions

*Made 2026-11-19.*
1. **Resume is stored in drift from Phase 4.** The `watch_history` table and its repository are built now (save and read). Phase 5 only adds the Library UI and the metadata refresh.
2. **The seek bar always runs left → right**, in Arabic too. The ±10 s buttons, double-tap zones and the brightness/volume halves follow the same physical direction. Only the top bar's text and chips follow RTL.
3. **Next episode autoplays with a countdown.** An "Up next" card appears near the end, and a 10 s countdown starts the next episode. **Next episode** is always available.
4. **Extras in Phase 4:** subtitle size and delay, seek-bar previews (moved up from Phase 7), and a controls lock on mobile.
5. **Not in Phase 4:** picture-in-picture, casting, background audio, lock-screen media controls (§12).
6. Already decided (PLAN.md §4.1): 2160p is a normal quality, with an always-visible quality chip. "Arabic (styled)" is an extra subtitle choice for ASS tracks. Stream URLs are fetched right before playing and again on a 403. When the API fails, ask the status page once.
7. **Android plays with ExoPlayer, not mpv** (*2026-11-19, after real-phone tests*). media_kit copies each decoded frame back to memory and draws it into a Flutter texture; 4K stuttered visibly on the owner's phone, even after `framedrop=no` cut the dropped frames to 0. `ExoPlayerEngine` (video_player 2.14) decodes in hardware into a Flutter texture with no copy back to memory. *Not* the SurfaceView platform view: Flutter draws that above every widget, so the controls only showed on the letterbox bars. **Confirmed on the owner's phone (2026-11-19): 4K is smooth and the controls work.** **Cost:** no styled (ASS) subtitles on Android; plain tracks are downloaded with the shared headers, parsed in Dart (SRT/VTT) and drawn by the Flutter layer as before. Desktop keeps media_kit. Where the two engines behave differently, this file says so with **Android (ExoPlayer)**; the mpv-on-Android findings in §13 stay for reference.

## 3. What already exists

| Piece | Where | Notes |
|---|---|---|
| Streams, highest first, refetched past the API cache when stale | `MediaRepository.streams` | Add `streams(id, fresh: true)` to always bypass the cache after a 403 (a URL can claim days of validity and still fail) |
| Subtitles, one plain track per language, plus styled ASS | `MediaRepository.subtitles`, `oneTrackPerLanguage` | `MediaDetails.subtitles` also carries them |
| Intro ranges | `MediaDetails.introRanges` (`SkipRange.contains`) | 1–3 ranges |
| Seek previews | `MediaRepository.seekPreview`, `SeekPreview.frameAt` | `null` for 49% of titles |
| Episodes, sorted, with labels | `MediaRepository.episodes`, `Episode.numbering` | Never episode titles |
| Default quality and subtitles | `settingsProvider` (`PreferredQuality.height` = `VideoSource.height`) | |
| Shared headers | `ApiClient.defaultHeaders` | Passed to `Media(httpHeaders:)`. Never copied |
| Status page | `StatusRepository.cinemanaHealth()`, `ErrorView` / `errorMessage` | |
| Packages | media_kit 1.2.6, media_kit_video 2.0.1, media_kit_libs_video (desktop), video_player 2.14 (Android), drift + drift_flutter, wakelock_plus, screen_brightness, volume_controller, window_manager 0.6.0 | `MediaKit.ensureInitialized()` already runs in `main.dart` |
| Where Play plugs in | `details_screen.dart`, `home_hero.dart`, `episode_list.dart` | Wired in M2 through `openPlayer` |

**media_kit facts this plan relies on** (read from the package source):
- `Media(uri, httpHeaders:, start:)`: per-media headers and a start position.
- `SubtitleTrack.uri(url, title:, language:)` loads an external subtitle file.
- `PlayerConfiguration`: `bufferSize` (default 32 MB, which is only about 12 s of 4K), `libass`, `libassAndroidFont` / `libassAndroidFontName` (Android only, set before mpv starts), `title`.
- Its mpv defaults: `cache=yes`, `cache-on-disk=yes`, `hr-seek=yes`, **`network-timeout=5`** (too short for multi-GB files on a slow node), `keep-open=yes`.
- `NativePlayer.setProperty(name, value)` sets any mpv property at runtime.
- The `Video` widget hides its own subtitle text when `libass` is on, but `SubtitleView` is exported, so we can place our own.
- Hardware decoding is on by default (`hwdec: auto`).

## 4. Architecture

```
lib/
  core/
    player/
      player_engine.dart        # PlayerEngine interface: open, play/pause, seek, rate, volume, subtitle, streams of state
      media_kit_engine.dart     # desktop: the only file that imports media_kit (mpv options, headers, error mapping)
      exo_player_engine.dart    # Android: the only file that imports video_player (texture view, SRT/VTT parsing)
      subtitle_fonts.dart       # copies the bundled Arabic font to disk for libass (desktop)
    storage/
      database.dart             # drift DB (watch_history now; favorites and downloads later)
  data/
    models/
      playback_request.dart     # what to play: a title, an optional episode, an optional start
      watch_progress.dart       # one row of watch_history, plus isFinished / resumeAt rules
    repositories/
      library_repository.dart   # watch_history: save, read, latest per series (favorites in Phase 5)
  features/player/
    player_screen.dart          # route page: Video + overlay layers, lifecycle (orientation, wakelock, fullscreen)
    player_controller.dart      # PlayerController (Riverpod Notifier): the playback session
    player_state.dart           # immutable PlayerState (source, quality, subtitle, speed, fit, status, error…)
    quality.dart                # pickQuality(): closest to the preference
    subtitles.dart              # subtitle choices and the default pick
    up_next.dart                # next-episode rules and the countdown
    widgets/
      controls_overlay.dart     # scrim, top bar, centre buttons, bottom bar, auto-hide
      seek_bar.dart             # played / buffered / thumb, LTR, scrub with preview
      seek_preview_frame.dart   # one sprite cell, drawn with drawImageRect
      chip_menus.dart           # subtitles, quality, speed, fit: sheet below 600 dp, popover from 600 dp
      subtitle_layer.dart       # Flutter-drawn plain subtitles (size setting, lifts above the controls)
      skip_intro_button.dart
      up_next_card.dart
      episodes_panel.dart       # series: pick another episode without leaving the player
      gesture_layer.dart        # mobile: taps, double-tap seek, swipes, lock
      shortcuts.dart            # desktop: Shortcuts/Actions and mouse handling
```

**Rules**
- **Only `media_kit_engine.dart` imports media_kit, and only `exo_player_engine.dart` imports video_player.** Everything else talks to `PlayerEngine`, so the controller is unit-tested with a `FakeEngine` and the screens are widget-tested without native code. Engine differences are flags on the interface (`supportsStyledSubtitles`, `errorsStopPlayback`), never platform checks in the controller.
- **What every engine promises** *(2026-11-24)*: `open()` never throws (a file that can't open is an `errors` event), the latest `open()` wins (an overtaken one closes whatever it made and reports nothing), and once `dispose()` has started every call is a no-op, nothing is reported, and no native player is left behind. Before this, a quality or episode switch while the first file still set up left a second native player playing behind on both engines, and closing the player mid-open threw (`StateError` on ExoPlayer, `"[Player] has been disposed"` on mpv). ExoPlayer re-checks after every await of `open()`; mpv runs its opens one after another and stops a setup the close overtook.
- **`PlayerController` owns the session.** Screens call intents like `togglePlay()`, `seekBy()`, `selectQuality()`, `selectSubtitle()`, `nextEpisode()`. The controller also owns recovery and saving progress.
- **Headers:** the engine receives `ApiClient.defaultHeaders` and passes it to `Media(httpHeaders:)`. Subtitle URLs and sprite sheets get the same headers (sprites through `MediaImage` or the shared header map).
- **Sources are a sealed type:** `RemoteSource(videoId)` now, `LocalSource(filePath, subtitlePath)` in Phase 6, so offline playback reuses the same player.
- **Route:** `/watch/:id` is a **top-level route on the root navigator**, outside the tab shell, so the nav bar is hidden. `openPlayer(context, request)` goes in `navigation.dart`. The `PlaybackRequest` travels as `extra`. A bare `/watch/:id` (deep link, hot restart) rebuilds it from the ID.
- **Performance:** the `Video` texture is never inside an `Opacity`, `ClipRRect` or `saveLayer`. Controls fade with one `FadeTransition` on the overlay only. Position text updates at most 4× a second, and the seek bar is a `RepaintBoundary` driven by a `ValueListenable`. `PlayerState` excludes the position, so menus and chips don't rebuild every tick.

## 5. Engine setup

**Android (ExoPlayer):** `ExoPlayerEngine` uses ExoPlayer's defaults: hardware decoding, its own buffer, and its own retries of a failed read (then it stops with an error, §6). The only settings are the texture view (decision 7) and the shared headers. The table below is mpv only.

**mpv (desktop)** is set in `media_kit_engine.dart`, once per player. The "mobile" values below were measured on Android before decision 7 and no longer run anywhere (Apple platforms were dropped on 2026-11-22).

| Option | Value | Why |
|---|---|---|
| `bufferSize` | 64 MB mobile, 192 MB desktop | 32 MB holds about 12 s of 4K (22 Mbit/s). Read-ahead must cover several seconds of 4K |
| `ytdl` | `no` | Otherwise mpv runs its youtube-dl hook on every failed URL (seen in M0): a slow, useless subprocess |
| `network-timeout` | `20` | The default 5 s drops slow CDN nodes on the tail read that non-fast-start files need |
| `demuxer-readahead-secs` / `cache-secs` | 20 / 60 (desktop), 20 / 30 (mobile) | Fast seeks near the playhead without filling a phone's memory |
| `cache-on-disk` / `demuxer-cache-dir` | `yes` desktop (`<cache>/mpv-cache`), **`no` mobile** | On Android the disk cache fails ("Failed to create file cache", M0). On Windows it failed with the same error until `demuxer-cache-dir` was set; on Linux it also keeps the cache out of tmpfs `/tmp` |
| `framedrop` | default desktop, **`no` mobile** | On a real phone (CPH2423) 4K dropped 14–20 frames per 25 s that were never late (`vo-delayed-frame-count` 0): a visible stutter. With `no`: 0 dropped, full 23.976 fps. Rendering tweaks (1080p surface, `gpu-dumb-mode`, `opengl-swapinterval=0`, `display-resample`) didn't help; `mediacodec_embed` only halved it. (Measured by `player_4k_test.dart`, removed at M9 with decision 7.) |
| `hwdec` | `auto` (default) | 4K H.264 needs hardware decoding on phones. Fall back to `no` once on decoder errors |
| `libass` | `true` | Needed for the styled ASS track (§7.2) |
| `sub-visibility` | toggled per track at runtime | Plain tracks are drawn by Flutter, styled tracks by libass (§7.2). Works at runtime (M0) |
| `title` | the media title | Window and task-switcher title on desktop |

There are no HTTP reconnect options. On Linux, mpv 0.42 reads over its curl backend, which resumes a cut connection by itself ("retrying from <offset>"). ffmpeg (as measured on Android in M0) does the same ("Will reconnect at …"). The controller's own recovery (§6) covers the rest.

## 6. Playback flow

**Opening a title** (`PlayerController.open(request)`):
1. **In parallel:** `details` (if not passed in), `streams`, `subtitles`, `seekPreview`, the saved progress, and for a series the episode list.
2. **Pick the quality** (§7.1) and the subtitle (§7.2).
3. **Pick the start:** the request's `start`, or the saved position if resume applies (§7.6), or 0.
4. **Open** `Media(url, httpHeaders: defaultHeaders, start:)`, add the subtitle track, set the speed, then play.
5. **While playing:** save progress (§7.6), watch for intro ranges (§7.5) and the end of the episode (§7.7).

**Failure and recovery** (inside the controller):

| What happens | What the player does |
|---|---|
| The stream answers 403, or mpv can't open it | Remember the position, call `streams(id, fresh: true)`, reopen the same quality at that position. Once per minute at most; after that, show the error. **mpv doesn't report the HTTP status reliably** (M0: "Failed to open <url>." on every platform, sometimes "HTTP error 403" in the log), so every open failure is treated as a possibly expired URL |
| An open fails | media_kit sends "Failed to open …" on its error stream, **but `buffering` stays `true` and nothing else changes** (M0). The controller leaves the loading state itself |
| **The file "completes" early** | When a reconnect fails mid-play (for example the URL expired), mpv plays out its buffer and **reports `completed` with no error**: 0:16 of a 2:29:17 film in M0. A completion counts only when the position is within 5 s of the duration. Otherwise it's a stream failure and goes through recovery. Without this rule, autoplay would jump to the next episode |
| The network drops mid-play | mpv reconnects first (M0). If playback is "playing" but the position hasn't moved for 15 s, reopen at the last position with backoff (2, 5, 10 s). Show "Reconnecting…" over the loader. This watchdog also catches a video output that failed silently (M0 on the emulator: `playing=true`, no error, no frames) |
| **Android (ExoPlayer): a stall is not a pause** *(2026-11-24)* | ExoPlayer's `isPlaying` means frames are moving, so it drops at every stall. On a weak connection it flipped many times a second, and the player took each flip as pause/play: the Play/Pause icon flickered, the TV controls kept popping up and taking the focus (from Skip intro), and OK during the stall played instead of pausing, until the buffer recovered or the 15 s watchdog reopened the file (seen once on the TV). The engine now reports `playing` as asked for (play, pause, the end of the file), as mpv does, and a stall only as `buffering`. |
| **Android (ExoPlayer): an error mid-play** | ExoPlayer retries a failed read itself; when it gives up (an expired URL, a long drop) it **stops for good**, paused too, and video_player resets the position and duration to 0. So the engine keeps the last good values (it never sends that 0), reports `errorsStopPlayback`, and the controller recovers at once, at the same position and keeping pause, instead of waiting for the watchdog. ExoPlayer never "completes" early. A failed open stays "buffering", like mpv. *Without this, the film reopened at 0:00 after 15 s, or stayed stuck when paused (fixed 2026-11-19).* |
| The streams or details request fails | `ErrorView` (it asks the status page once, so "Cinemana is having problems" when it's down) with **Try again** |
| No streams at all | "This title isn't available right now", with Back (not Try again, which can't help) |
| Decoder error | mpv falls back to software decoding by itself (`hwdec=auto`), so its errors aren't read. ExoPlayer has no software switch: `PlayerEngine.isDecoderError` spots its renderer errors, and the player moves to the next lower quality at the same place, for the rest of the session, with a note ("This device couldn't play 4K, so it switched to 1080p."). At the lowest quality the usual recovery runs, then the error view. *Built in M9* |
| A subtitle fails to load | Keep playing without it and show a short note: "Subtitles couldn't be loaded" |
| The status page is checked | Only after API calls fail, never for CDN errors |

Every error message goes in the ARB files.

## 7. Features

### 7.1 Quality
- **Default:** `pickQuality(sources, preferred)` takes the exact match, else the nearest **lower** quality, else the lowest one above it. 2160p counts like any other quality.
- **Chip:** always visible in the top bar: "1080p", or "4K" for 2160p (`bulb` badge style, DESIGN.md §5).
- **Menu:** every available quality, highest first, with the current one in `bulb` and a check. 2160p shows "4K · about 10 GB per hour" as its caption.
- **Switching:** reopen the new URL at the current position, keeping pause state, speed and the subtitle (external tracks are re-added after `loadfile`). The old frame stays on screen until the new one arrives.
- The pick in the menu applies to this session (and the next episodes), not to Settings.

### 7.2 Subtitles
- **Default from Settings:** Arabic, English or Off. If the language is missing, use Off and show nothing (no silent switch to the other language).
- **Choices:** Off, then one plain track per language (SRT preferred, `oneTrackPerLanguage`), then **"Arabic (styled)"** when an ASS track exists. Plain Arabic stays the default.
- **Android (ExoPlayer):** "Arabic (styled)" isn't offered (`supportsStyledSubtitles` is false). Plain tracks are downloaded with the shared headers (`ApiClient.fetchText`), parsed in Dart (SRT/VTT) and drawn by the same Flutter layer. The delay is applied in Dart, and the size is the Flutter layer's own.
- **How they're drawn on mpv (hybrid):**
  - **Plain tracks:** mpv parses the file, `sub-visibility=no`, and `subtitle_layer.dart` draws the current text from the player's subtitle stream in Flutter. It uses IBM Plex Sans Arabic / IBM Plex Sans (cream text with a dark outline, no box). It lifts above the controls when they're shown, stays on screen in Fill mode, and follows the size setting. Each line gets its own `Directionality` from its script.
  - **Styled ASS track:** `sub-visibility=yes`, so libass renders it into the frame with its own styles. The Flutter layer hides.
  - **Font for libass:** the ASS files name fonts the device won't have ("Bahij Nassim", "GE SS Text"). Bundle **IBM Plex Sans Arabic Regular** as the fallback. *M0: with only the Medium file libass rendered nothing, and the Regular file works.* `subtitle_fonts.dart` copies it from the assets to the app support folder at startup and sets `sub-fonts-dir` / `sub-font`. (*Before decision 7, Android needed `libassAndroidFont` / `libassAndroidFontName`, because media_kit's Android controller sets `sub-font-provider=none`.*)
- **Size** (new setting, Settings → Playback): Small, Medium (default), Large. It applies to plain tracks, and to ASS through `sub-scale` (0.85 / 1 / 1.2).
- **Delay:** in the subtitle menu, "Sync" with −0.5 s / +0.5 s steps and a reset, shown as "+1.5 s". On mpv it's `sub-delay` (both renderers); on ExoPlayer the engine shifts the parsed cues. It's kept for the rest of the session (not saved).

### 7.3 Speed
0.5×, 0.75×, 1×, 1.25×, 1.5×, 1.75×, 2× with pitch correction (the default on both mpv and ExoPlayer). The chip shows "1×". It's kept for the session, across episodes.

### 7.4 Fit
**Fit** (whole frame, letterboxed; the default), **Fill** (crop to fill the screen), **Stretch**. The chip cycles through them (icon plus a short toast "Fill"). There's no pinch to fill: the owner removed it (2026-11-22); two fingers do nothing. Done with `PlayerEngine.buildVideo(fit:)` (`Video(fit:)` on mpv, a `FittedBox` on ExoPlayer). Plain subtitles stay on screen in Fill because Flutter draws them.

### 7.5 Skip intro
- While the playhead is inside an intro range (`SkipRange.contains`), show **Skip intro** (outlined pill, at the end side above the seek bar, as in the design). It jumps to the range's `end`.
- The button stays visible even when the controls are hidden, and for 8 s at most per range, then folds into the controls.
- Desktop: **S** skips. On a two-range title (cold open, then intro) each range gets its own button.
- *Built (M6):* `PlayerState.intro` (the range under the playhead) and `introPinned` change only when the playhead enters or leaves a range, so the button costs nothing per tick. A range is pinned once per load: seeking back into it shows the button with the controls only. The Up next card wins if both would show.

### 7.6 Resume and history (drift)
- **Table `watch_history`:**
  - `videoId` (primary key: the movie or episode ID)
  - `seriesId` (null for movies), `season`, `episode`
  - `positionMs`, `durationMs`, `finished`, `updatedAt`
  - display metadata: `titleEn`, `titleAr`, `posterUrl`, `kind`
  - Never stream URLs.
- **Saving:** every 10 s while playing, plus on pause, after a seek, on episode change, on leaving the player, and when the app goes to the background (`AppLifecycleListener`). Writes are cheap upserts.
- **Finished:** 95% watched, or less than 2 min left once past the halfway mark (a video under 4 min would otherwise be finished from its start; *2026-11-24*). A finished episode resumes the series at the next one.
- **Resume:** offered when ≥ 30 s were watched and the video isn't finished. The player starts there directly and shows "Resuming from 14:32 · Start over" for 5 s.
- **Details:** the primary button becomes "Resume · S2 E5 · 14 min left" (DESIGN.md §8), and episode rows show progress and watched numerals (DESIGN.md §5).
- **Home's Continue watching row** reads the same table: the newest movie or episode of each title. Unfinished ones resume; a finished episode shows its next one as "Up next" (Phase 5, `continueEntriesProvider`, shared with the Library tab). A card plays straight away, and the player resumes by itself.
- *Built (M4):* `lib/core/storage/database.dart` (drift, `drift_flutter`), `LibraryRepository` (`DriftLibraryRepository`; `MemoryLibraryRepository` for tests, because drift's timers don't mix with widget tests). The screen saves on leaving and on `AppLifecycleListener` hide/inactive (a provider can't save from its own dispose).

### 7.7 Next episode and Up next
- **Next** = the next entry in the sorted episode list, across seasons. Double episodes are one entry. Nothing after the last episode.
- **Next episode** button at the end of the bottom bar (design). Desktop: **N**.
- **Up next card:** it appears at the "finished" point (less than 2 min left or 95%), in the bottom end corner. It shows the season image, "Up next · Season 2 · Episode 6", **Play now** and **Hide**. In the **last 10 s** a countdown ring fills, then the next episode starts. If the file ends sooner (a short credits roll), the countdown starts at the end.
- **Still watching?** After 3 automatic episodes in a row with no input, pause and ask "Still watching?" instead of continuing (saves data overnight, especially in 4K).
- **Episodes panel** (series only): an "Episodes" button next to Next episode opens a side panel (bottom sheet on phones) with the season chips and episode rows from Details. Picking one switches in place and keeps quality, subtitle choice and speed.
- *Built (M5):* the rules are in `up_next.dart` and `PlayerController` (`PlayerState.upNext`: none, card, countdown, stillWatching), drawn by `up_next_card.dart`. The controller's 10 s timer starts the next episode; the ring is only a picture. Choices made while building:
  - **Pause** stops the countdown and keeps the card. Playing again in the last 10 s starts a full countdown.
  - **Hide** also cancels autoplay for that episode. Next episode stays available. A seek back before the finished point hides the card, and it comes back when the playhead returns (unless hidden).
  - **"Still watching?"** is the same card, paused, with Play now and Hide (no extra dialog). "Input" is any tap, key, mouse move or choice in the player (`noteActivity`), so hovering a desktop window counts.
  - The **Episodes panel** reuses Details' `EpisodeList` (it marks the current episode) as a side sheet from the end edge from 600 dp, so landscape phones get the side panel too, and a bottom sheet below 600 dp. A picked episode plays even if the player was paused.

### 7.8 Seek-bar previews
- When dragging the thumb or hovering the bar (desktop), show the frame from `SeekPreview.frameAt` above the thumb (radius 6, with the time under it). It's 90 dp tall on a phone and grows with the window to 150 dp on a big monitor (9% of the width), and it takes **the video's shape** (`PlayerEngine.aspectRatio`), not the sprite cell's: the server squeezes every frame into a 16:9 cell, so a 1.9:1 film looks squashed if drawn at 16:9 (seen on Avengers: Endgame). The source frames are only 120×68 with 256 colours, so they're drawn with `FilterQuality.high` (soft, not blocky). *Checked 2026-11-19:* the website uses the same sheets at 120×68 CSS px, time over the picture, squashed; there's no sharper source. The owner chose this size over a smaller, sharper one. No frame (title without sprites, broken sheet, past the last sheet) = the time alone.
- Sheets load through the shared headers and the image cache. Prefetch the sheet under the playhead and the next one when the player opens. The frame is drawn with `drawImageRect`, not by cropping a widget.
- *Built (M6):* `seek_preview_frame.dart` (`seekSheetImage` is the one provider for both the prefetch and the frame, so the frame comes from the cache). Sheets are decoded at full size (1200 px), because the cells are in source pixels. The bubble stays inside the bar's width. *Bug found while building:* wrapping the bar in a `Stack` only while dragging rebuilt its gesture detector and dropped the drag, so the bar is always inside the `Stack`. *Found on the phone:* a finger on the thumb hid the bubble (the time alone is only 24 dp tall), so a touch drag lifts it 28 dp higher (56 dp was too far); mouse hover keeps it next to the bar.

### 7.9 Buffering and loading
- Opening and seeking outside the buffer: `BulbLoader` in the centre, controls still usable.
- Buffering mid-play: the loader replaces the play/pause icon inside the `bulb` circle after 300 ms (no flicker on short stalls).
- The seek bar shows the buffered range in `velvetStrong` (design).

## 8. Controls (from the design mock)

**Layout** (landscape, controls over a 60% `night` scrim):
- **Top bar:**
  - Start side: back, then the title (`title` style) and "Season 2 · Episode 5" (`caption`, `dust`).
  - End side: outlined chips for **subtitles** ("Arabic"), **quality** ("1080p" / "4K"), **speed** ("1×"), and **fit**.
  - Desktop adds a **fullscreen** button. Mobile adds the **lock** button.
- **Centre:** back 10 s, the `bulb` play/pause circle, forward 10 s.
- **Bottom:**
  - Above the bar, at the end side: **Skip intro** or the Up next card.
  - Then elapsed time, the seek bar (`bulb` played, `velvetStrong` buffered, `velvet` track), and the remaining time ("−28:18").
  - Last: **Episodes** (series) and **Next episode**.
- **Portrait on phones:** the player forces landscape, so there's no portrait layout. Tablets and desktop windows use the same layout at any size. Below about 480 dp wide, the chips collapse into one "⋯" menu.

**Visibility:**
- Controls show on tap, mouse move or a key press, and hide after 3 s of no input while playing.
- They stay visible while paused, while a menu is open, while scrubbing and during errors.
- A tap on the video hides them, paused too. A tap outside an open menu (or back, or a swipe down on the sheet) closes the menu and hides them; picking something keeps them up.
- **Skip intro** and the Up next card stay visible when the controls hide.

**Menus:** each chip opens a bottom sheet below 600 dp and an anchored popover from 600 dp (like `showChoicePicker`). One row per choice, with the current one in `bulb` and a check. Playback continues while a menu is open.

**RTL:**
- The seek bar, the times on either side of it, the ±10 s buttons and the gesture zones keep their **physical** positions (decision 2).
- Times use Western digits (DESIGN.md §2).
- The top bar, the chip order, the menus, Skip intro, the Up next card and the Episodes panel follow `start`/`end`.

## 9. Platform specifics

### 9.1 Mobile (Android)
- **On enter:** landscape only, immersive mode (`SystemUiMode.immersiveSticky`), wakelock while playing. **On exit:** restore the browsing orientation (auto-rotate by default, or portrait if locked in Settings: `setBrowseOrientation`), system UI, wakelock and brightness.
- **Gestures** (`gesture_layer.dart`, physical sides):

| Gesture | Action |
|---|---|
| Tap | Show or hide the controls |
| Double-tap left / right third | −10 s / +10 s. Repeated taps add up ("+30 s") with a ripple on that side |
| Vertical drag, left half | Brightness (app-level, through `screen_brightness`, restored on exit) |
| Vertical drag, right half | Volume (system volume through `volume_controller`, without the system slider) |

  - Drags start 24 dp from the screen edges, so the system back gesture and notification shade still work.
  - The brightness and volume levels show as a slim vertical bar (`bulb` on `velvet`) with an icon.
- **Controls lock:** a lock button in the top bar. While locked, touches are ignored except a small unlock button that appears on tap and hides after 3 s.
- **Audio interruptions:** pause on headphone unplug, incoming calls and other apps taking audio focus. This needs **`audio_session`** (new dependency): it is the standard package for this and doesn't add background playback.
  - *Built (M7):* `lib/core/player/audio_focus.dart` is the only file that imports it. **audio_session owns audio focus on every platform, and ExoPlayer is told not to take focus itself** (`VideoPlayerOptions(mixWithOthers: true)`): two focus requests from one app take focus from each other (ExoPlayer would pause itself), and audio_session only reports unplugged headphones while it holds focus. A short interruption (a call) resumes afterwards; another app taking the sound for good doesn't; a notification "duck" doesn't pause.
- **Back:** the system back button or gesture leaves the player (saving progress), or unlocks first when locked, or closes an open menu first.
- *Built (M7):* `gesture_layer.dart` (the only place that touches brightness and volume). Choices made while building:
  - A single tap on a side third waits 250 ms for a second tap before toggling the controls; the middle third toggles at once. After a double tap, more taps on that side within 0.7 s keep adding 10 s.
  - **No swipe-to-seek** (*owner's decision, 2026-11-19*): a sideways swipe over the video does nothing; seek with the bar, double taps or ±10 s. Swipes are measured from where the finger came down: a scale gesture only starts past its slop (about 36 dp later), which was too late for the 24 dp edge check.
  - The seek bar still wins its own drags, and the buttons their taps.
  - The lock hides Skip intro, Up next and "Resuming from", and unlocks by itself for errors, the end and "Still watching?".

### 9.2 Desktop (Linux, Windows)
- **Mouse:**
  - Moving shows the controls. The cursor hides with them after 3 s.
  - Click on the video = play/pause. Double-click = fullscreen. Scroll wheel = volume.
  - Hover states on every control. Hovering the seek bar shows the preview and time.
- **Fullscreen** through `window_manager` (enter, exit, and restore the previous size).
- **Volume** is mpv's volume (0–100), saved in preferences.
- **Keyboard** (`Shortcuts`/`Actions`, the same keys in both languages):

| Key | Action |
|---|---|
| Space, K | Play / pause |
| ← / → | −10 s / +10 s |
| Shift + ← / → | −60 s / +60 s |
| ↑ / ↓ | Volume ±5 |
| M | Mute |
| F, double-click | Fullscreen |
| Esc | Leave fullscreen, else close a menu, else leave the player |
| S | Skip intro |
| N | Next episode |
| C | Next subtitle choice |
| [ / ] | Slower / faster |
| 0–9 | Jump to 0–90% |

- Every control is reachable with Tab and has a 2 px `bulb` focus ring (DESIGN.md §5).
- *Built (M8):*
  - **Full screen** goes through `lib/core/platform/full_screen.dart` (window_manager 0.6's native `WindowManager.instance.getCurrent()`, the only file that imports it; tests override `fullScreenProvider`). Checked on the Linux window: it fills the monitor and gives the previous size back. Leaving the player restores the window as it was when the player opened.
  - **Click** plays or pauses at once; a **double click** is two clicks (so playback ends up as it was) plus full screen, as on YouTube. A real double-tap recognizer would hold every button's tap for 300 ms.
  - **Volume** (keys, wheel, M) shows a short note ("95%", "Muted") and is saved as `playerVolume`. From mute, ↑ or the wheel starts at 0.
  - **Esc** leaves full screen first, then the player. Menus close themselves on Esc (they are routes).
  - The focus ring is `withFocusRing` (`controls_overlay.dart`), over each button's own border.
  - **Windows:** not run yet (no Windows machine). Everything here is Flutter or window_manager, which supports Windows.

## 10. Milestones

Each milestone ends with something that runs, and is checked on **Android and Linux**. Windows is checked from M8 on (needs a Windows machine or VM).

| # | Milestone | Done when |
|---|---|---|
| **M0** ✅ | **Spike** (`integration_test/player_spike_test.dart`, removed at M9 ✅; results in §13): play a 1080p non-fast-start movie, a 4K movie and an anime episode with headers; measure start time; hybrid subtitles (Flutter-drawn SRT plus libass ASS with the bundled font, on Android and Linux); `sub-fonts-dir` at runtime on desktop; how a 403 and a network drop look on the error/log streams; quality switch at a position; 4K on the emulator and on a real phone | The numbers and findings are written into §5 and §13 of this file, and any choice they overturn is changed here first |
| **M1** ✅ | `PlayerEngine`, `MediaKitEngine`, `PlayerController` and `PlayerState`, no UI. `pickQuality`, subtitle choice, recovery (403 → `streams(fresh: true)`), `streams(fresh:)` in `MediaRepository` | Unit tests with `FakeEngine` cover open, quality pick, subtitle pick, 403 recovery, network-drop recovery and errors |
| **M2** ✅ | `/watch/:id` route, `openPlayer`, the player screen with the basic controls (back, play/pause, ±10 s, seek bar, times, buffering loader, auto-hide). Play wired from Details, the hero and episode rows | A movie and an episode play from the app, on Android and Linux |
| **M3** ✅ | Chip menus: subtitles (with size and delay), quality, speed, fit. Settings → Subtitle size | Every switch keeps the position and the other choices |
| **M4** ✅ | drift `database.dart`, `watch_history`, `LibraryRepository`, saving and resume, Details' Resume button, episode progress in the rows, Home's Continue watching row | Force-stop mid-episode, relaunch, and resume within 10 s of where it stopped |
| **M5** ✅ | Series: Next episode, the Up next card and countdown, "Still watching?", the Episodes panel | A full season plays through by itself, and switching episodes keeps the choices. *Checked on the owner's phone 2026-11-19* |
| **M6** ✅ | Skip intro and seek-bar previews | Both work on a title that has them, and nothing shows on one that doesn't. *Checked on the owner's phone and on Linux (live API) 2026-11-19* |
| **M7** ✅ | Mobile: orientation (done early, 2026-11-19: `setPlayerOrientation` and restoring the browsing choice, see AGENTS.md), immersive mode, wakelock, gestures, the lock, `audio_session` interruptions | Checked by hand on a real Android phone (the emulator shows no video), including the ExoPlayer failure checks in §13. *Checked on the owner's phone 2026-11-19* |
| **M8** ✅ (Linux) | Desktop: shortcuts, mouse, cursor hiding, fullscreen, saved volume. First Windows run | Every shortcut in §9.2 works on Linux and Windows. *Linux ✅ (owner, 2026-11-19); Windows not run yet (no machine)* |
| **M9** ✅ | Hardening: profile mode on a mid-range phone (60 fps controls, memory with 4K), Arabic/RTL pass, every error state, the integration test | Every target in §1 is met, and PLAN.md §4.1 Player is ticked. *Done 2026-11-19: results in §15. Windows still to run* |

## 11. Testing
- **Unit:**
  - `pickQuality` (exact, lower, higher, 4K, missing 1080p).
  - Subtitle choice (missing language, styled only).
  - `isFinished` / resume rules.
  - Next-episode order (gaps, double episodes, season boundaries).
  - The Up next countdown and "Still watching?" (with `fake_async`).
  - Recovery paths, with `FakeEngine`, for both engine kinds (`FakeEngine(errorsStopPlayback: true)` acts like ExoPlayer).
- **Repository:** `LibraryRepository` on an in-memory drift database. `streams(fresh: true)` on the fake API client.
- **Widget** (`pumpApp`, `fixtureApi`, `FakeEngine` instead of media_kit):
  - Controls show and hide.
  - Chips and menus.
  - Skip intro inside and outside a range.
  - The Up next card.
  - The seek bar staying LTR in Arabic.
  - Keyboard shortcuts.
  - The locked state.
  - Error states.
- **Engines** *(2026-11-24)*: `test/core/player/exo_player_engine_test.dart` drives `ExoPlayerEngine` through a fake video_player platform (`fake_video_platform.dart`, which can hold initialize, the volume call and dispose so a test can land at any await): what it asks ExoPlayer for, its events and errors, the races above, subtitle timing and 600 seeded broken SubRip/WebVTT files. `integration_test/media_kit_engine_test.dart` does the same for mpv on the real libmpv with two clips ffmpeg makes (offline, about 90 s, needs `ffmpeg`), sweeping each race over 12 delays in both modes (one player, a player per file) and counting live native players (`MediaKitEngine.livePlayers`). media_kit's `open()` waits on the frame loop, so these are `testWidgets` with live frames; media_kit's libmpv doesn't play `av://lavfi:` sources.
- **Integration** (`integration_test/player_test.dart`, live API, Linux and the Android emulator): launch → open a movie → play 5 s → seek → change quality → leave → resume. Then the same for an episode, with Next episode.
- **Manual before release:** a 2-hour movie in 4K on desktop, a full anime season on a phone (plain subtitles; styled on desktop), airplane mode mid-play, and a 403 forced by editing a URL's signature in a debug build, on Linux and on the Android phone.

## 12. Not in this phase
- **Picture-in-picture:** not chosen for now. Android could add it later with a small native change (ExoPlayer makes it easier than mpv did).
- **Casting, background audio, lock-screen controls:** later, if wanted. `audio_session` is a first step toward them.
- **Audio track switching:** every file has one audio track (API.md §3).
- **Offline playback (built in Phase 6, 2026-11-19):** `PlayerController._load` asks `DownloadsRepository.playable` first. A finished download plays `file://…` with its saved subtitles and no stream request; ExoPlayer opens it with `VideoPlayerController.file`, and its subtitle loader reads `file:` URLs from disk. Details, previews and episodes wait at most 3 s (`offlineWait`), so a dead connection never holds up playback, and without a connection Next episode uses the downloaded episodes. Recovery reopens the file instead of fetching URLs. Checked live on Linux (`integration_test/downloads_test.dart`).
- **Long-press for 2× speed:** an idea for later.

## 13. M0 results (2026-11-19)

Measured with the `mpv` 0.42 command line (the same libmpv media_kit uses on Linux) and `integration_test/player_spike_test.dart` on Linux and the Android emulator. A local proxy cut connections and answered 403 on cue.

| Check | Linux | Android emulator |
|---|---|---|
| Start, 1080p (not fast-start), 4K, 720p, from 0 and from 1 h | First frame 0.6–0.9 s, playing 1.1–1.5 s | Playing 3.3–5.5 s, **but no picture** (below) |
| Seek outside the buffer (1080p, to 30 and 120 min) | 0.7–1.0 s | n/a |
| Quality switch 720p → 1080p at 10:02 | 0.7 s, same position, still playing | n/a |
| Plain SRT with `sub-visibility=no` | Text arrives on `player.stream.subtitle`, nothing burned in | n/a |
| Styled ASS with `sub-visibility=yes` | Rendered by libass. `sub-text` is **also** sent, so the Flutter layer hides by state | n/a |
| `sub-delay`, `sub-scale`, `sub-fonts-dir` at runtime | All work | n/a |
| Cut mid-play, then reconnect | Resumed by mpv | ffmpeg "Will reconnect" |
| Cut mid-play, then 403 | `completed=true` at 0:16 of 2:29:17, no error | n/a |
| 403 at open | Error "Failed to open …", `buffering` stuck `true` | n/a |

**CDN:** node `cndw2` accepts expired and forged signatures; `cndw1`, `3`–`6` answer 403. `cdn.shabakaty.com` picks the node, so expiry shows up only sometimes.

**Android emulator:** video never renders, with `vo=gpu` (mpv: "Could not create EGL context for GLES 2.x") or `vo=mediacodec_embed`, with Impeller on or off, even though decoding and the clock run. On the same `Player`, every `open()` after the first also failed to bring the video output back, while a new `Player` per file played. The emulator can't be used for video.

**Real phone with mpv (answered 2026-11-19, then replaced by decision 7):** video rendered, but 4K stuttered (§5 `framedrop`). `MediaKitEngine` still creates a new `Player` per file on Android (`recreatePerFile`), which only matters if Android ever goes back to mpv.

**Real-phone checks for ExoPlayer** (owner's device, release APK). Done: 4K is smooth and the controls draw over the video. The list below is from M2–M7:
1. Airplane mode for a few seconds mid-play: ExoPlayer resumes by itself, or the player shows "Reconnecting…" and comes back at the same position.
2. ✅ Airplane mode for a minute, while playing and while paused: the player recovers at the same position (paused stays paused), never at 0:00. *Confirmed on the owner's phone 2026-11-19, after the `errorsStopPlayback` fix (§6).*
3. An expired or forged URL signature (debug build): the player fetches fresh URLs and plays.
4. ✅ A quality switch and an episode switch keep the picture. *Checked by the owner with M3 and M5.*

`integration_test/player_engine_test.dart -d <phone>` runs the live engine checks (playback, quality switch, 4K, subtitles) on ExoPlayer. The mpv spike and 4K tests were removed at M9.

## 14. Risks and open questions

| Risk | Plan |
|---|---|
| ~~Non-fast-start 1080p files start slowly~~ | ✅ M0: no slower than fast-start files (about 1 s) |
| ~~The hybrid subtitles don't work~~ | ✅ M0: they work on Linux. Android draws plain tracks only (decision 7) |
| ~~libass on desktop ignores `sub-fonts-dir` set after start~~ | ✅ M0: works on Linux |
| 4K is too heavy for some phones (decoder or memory) | Hardware decoding by default. On decoder errors, fall back once and then offer 1080p. The always-visible chip makes the cause clear |
| Errors from mpv are strings, not codes | ✅ M0: don't parse them. Any open failure goes through the same recovery (fresh URLs, then the error view) |
| ~~Video output on real Android phones~~ | ✅ Decision 7: ExoPlayer in a texture renders and plays 4K smoothly on the owner's phone |
| ExoPlayer's failures differ from mpv's | It stops on every error and resets its position; handled with `errorsStopPlayback` (§6) and a unit test. A minute in airplane mode recovers on the phone (2026-11-19); the 403 check is still to do (§13) |
| Some Android phones can't decode 4K in hardware | ExoPlayer can't fall back to software like mpv, so the decoder fallback goes to a lower quality (§6, M9) |
| Windows has no dev machine yet | M8 needs a Windows machine or VM. The NVIDIA Linux bug (AGENTS.md) doesn't affect Windows |
| Possible 4K micro-stutter on weaker Windows 11 PCs *(unproven, 2026-11-26)* | Not reproduced on RTX 5070 (`d3d11va`, 0 dropped frames, `raster p95 = 0.56 ms`). Measure `hwdec-current` and drop counts on weaker hardware before changing defaults; see `docs/PACKAGING.md` §4 (Windows ANGLE double-4K `CopyResource` + `glFinish()` and `video-timing-offset=0` are Windows-only; `hwdec=auto` fallback and `framedrop=vo` are shared with Linux; Android uses ExoPlayer and is unaffected) |

## 15. M9 results (2026-11-19)

**Frame times on the owner's phone** (OnePlus CPH2423, 120 Hz), profile mode, **4K Avengers: Endgame playing on ExoPlayer**, from `integration_test/player_perf_test.dart`:

| Scenario | Frames | UI p99 | Raster p99 | Slowest | Over 8.3 ms |
|---|---|---|---|---|---|
| Playing, controls up (clock and seek bar ticking) | 957 | 2.4 ms | 7.3 ms | 10.4 ms | 0.3% |
| Controls fading in and out | 503 | 4.4 ms | 7.5 ms | 10.3 ms | 0.2% |
| Scrubbing the seek bar with previews | 598 | 1.0 ms | 5.4 ms | 6.1 ms | 0% |
| Opening and closing the quality menu | 729 | 7.2 ms | 8.0 ms | 13.0 ms | 0.7% |

No frame came near 16.7 ms, the §1 target (60 fps); the controls nearly hold 120 Hz. The decoder ran 3840×2160 at 24 fps with no dropped frames. **Memory:** 633–720 MB (RSS) after a minute of 4K.

**The §1 targets:**

| Area | Result |
|---|---|
| Start | About 1 s on Linux (M0). On the phone, 4K starts within seconds (owner) |
| Seeking | Inside the buffer: instant. Outside: 0.7–1.0 s on Linux (M0). One deep seek in a 2.5 h film took over 30 s once in three end-to-end runs (a slow CDN node) |
| Never stuck | Every failure ends in a message with Try again (or Back): expired URLs, dropped connections (ExoPlayer and mpv), early "completed", failed opens, decoder errors, API errors (30 s timeout, one retry) |
| Never lose progress | Saved every 10 s, on pause, seek, episode change, exit and when the app goes to the background (M4, checked with a force-stop) |
| Smooth controls | Above |
| Switching keeps your place | Unit and widget tests; checked on the phone (M3, M5) |
| Works everywhere | Android and Linux, touch and keyboard/mouse, English and Arabic (RTL pass on Linux screenshots). **Windows not run yet** (no machine) |

**Tests:** `integration_test/player_test.dart` (the player end to end on the live API: a movie and an episode) passes on Linux. The M0 spike and the mpv 4K test were removed.

**Still open after M9** (none of them block Phase 6):
- **Windows:** never run (no machine). Check every shortcut in §9.2, the mouse, full screen and playback.
- **§13 checks 1 and 3 on the phone:** a few seconds of airplane mode mid-play, and a forged URL signature (debug build). The code paths are covered by unit tests.
- **The manual checks before release (§11)** that are left: a 2-hour 4K movie on desktop, and a full anime season playing through by itself on the phone (plain subtitles; styled ones are desktop only).
- **Later, outside this plan (§12):** picture-in-picture, casting, background audio, lock-screen controls, long-press for 2×.

