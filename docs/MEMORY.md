# Memory: the investigation and fix plan

> **Status (2026-11-26, evening):** M0 and M1 done, except the TV (not available yet). M2 is under way: the performance baseline is recorded for this PC (again after #8, below), the laptop and the phone (§5, M2's first box). Fix 1 (Linux `malloc_trim`) is done and kept, but gives back only ~35 MB now that #8 moved mpv's buffer out of the heap (finding 17). **Next: re-run the laptop's baseline on today's `main`, then fix 2** (Android GC), **then fix 4** (the arena cap, now desktop's main lever; fix 3 is moot on desktop, see its box). Each fix is measured against the baseline and kept only if no performance number got worse (§2.1: performance comes first). Tick each box as it's done, with the date and the numbers. **Read this before changing caches, buffers, or how the player opens and closes.**

> **Changed since the first baseline (2026-11-26, PRs #7–#11 merged):** #8 gives mpv's disk cache its own folder (`demuxer-cache-dir` = `<cache>/mpv-cache`). Without one, mpv's cache file never opened and the whole buffer stayed in RAM: that was finding 8. With it, the buffer is on disk, and 4K uses 200–500 MB less (finding 17). #7 makes 4K the default quality, so 4K is what most users now play (the tests already ran at 4K). **The memory test now gives itself the app's folders** (`build/memory/appdirs`, as `initAppDirs` does for the app); `MEMORY_APP_DIRS=false` runs it the old way. Every report now ends with the app's own `memory` log lines (open, close, and what each trim gave back).

The goal: **memory comes back when a feature is done with it, and stays flat over a long session.** Closing the player returns the app to about what it used before the video. Ten videos in a row use no more than one. Browsing for an hour levels off. This matters most on the weakest devices we support: low-end phones and TVs with 1.5 to 2 GB of RAM, where Android kills the app in the background, or the TV stutters, long before a desktop notices.

## 1. What the owner saw (2026-11-25, Omarchy laptop, AppImage, mpv engine)

1. **Fresh start: about 250 MB.** While browsing it climbs slowly: 259, then the 260s.
2. **About 850 MB while a 4K video plays.** That could be reasonable (§3.1).
3. **After the video closes, the 850 MB stays.** It doesn't drop back towards 250.
4. Not checked yet: phones and TVs (ExoPlayer, a different engine), and Windows (mpv).

## 2. What "fixed" means (targets)

The numbers were set before measuring; M1 (§5) keeps them. Where each stands now:
- **T1** fails everywhere: +287 MB (laptop, before #8), +224 (this PC after #8; +423 before), +249 (phone) over start after the first close. With M2's fixes the experiments reached +93 (laptop, trim alone, before #8), +161 to +211 (this PC, trim, after #8: finding 17), +98 (phone, a Java GC). So T1 is reachable on the phone; on desktop what's left is mostly glibc's arenas (fix 4) and +54 MB of library code loaded once.
- **T2** passes once memory levels off (by the 5th video); measured over 10 videos it fails only from the first videos' climb. It becomes a real check once T1 holds.
- **T3** passes on Intel and the phone; on this PC only NVIDIA's driver breaks it (finding 5).
- **T4** passes on the phone, and on desktop after the last seek.
- **T5** is set per device from the M2 baseline: what each plays 4K with now, as the most it may use after M2.

| # | Target | Measured how |
|---|---|---|
| T1 | **Closing the player gives memory back:** 30 s after closing, RSS is within **+60 MB** of before the video opened | The cycle test (§4.1) |
| T2 | **No leak across videos:** after 10 open, play, close cycles, RSS after the 10th close is within **+20 MB** of after the 1st | The cycle test |
| T3 | **Browsing levels off:** scrolling all of Home and 3 genre pages, then idling 10 minutes, rises less than **+10 MB** in the last 5 minutes | The browse test (§4.2) |
| T4 | **4K playback stays bounded:** over 20 minutes of 4K, RSS rises less than **+20 MB** in the last 5 minutes (each seek steps it up before then, by design) | The long-play test (§4.3) |
| T5 | **Budgets per device:** while playing 4K, phone and TV stay under the numbers set in M1 (TV.md §9 measured 613 MB on the TCL) | The perf tests (`player_perf_test`, `tv_perf_test`) |

### 2.1 Performance comes first (owner, 2026-11-26)

**No memory saving is worth a slower app.** Every M2 change is measured against the baseline below, on the same device, before it's kept. If any number gets worse beyond the run-to-run noise, the change is reverted or reworked, whatever memory it saves.

| # | Must not get worse | Measured how |
|---|---|---|
| P1 | **4K playback:** mpv's dropped and late frames over 60 s of 4K (`frame-drop-count`, `decoder-frame-drop-count`, `vo-delayed-frame-count`); on the TV, `tool/tv_cadence.sh` | The perf baseline (M2, first item) |
| P2 | **Start and seek:** time from opening to the first frame; a seek inside the buffer stays instant, forward *and back* (the back buffer, finding 8); a seek outside it plays within 2 s (PLAYER.md §1) | The same |
| P3 | **No stalls:** no rebuffering during 20 minutes of 4K on a normal connection (mpv's `paused-for-cache`) | The long-play run |
| P4 | **Smooth UI:** frame times with the player's controls up (`player_perf_test`), scrolling (`scroll_perf_test`), the TV's Home and player (`tv_perf_test`) | The existing perf tests |
| P5 | **Going back is quick:** returning from the player to the page shows its posters without reloading them | Watch it, and the image cache's hits |

How each fix stays off the hot path:
- **`malloc_trim`** runs only after the player has closed, never while a video plays, and off the UI thread (it can take tens of milliseconds), so no frame waits for it.
- **The arena cap** is kept only if P1 and P3 stay the same: fewer arenas means mpv's threads share the allocator's locks.
- **The back buffer** keeps enough for an instant seek back of the usual jumps (−10 s, −30 s); P2 checks it.
- **Image cache caps** are lowered only if P4 and P5 stay the same: a cap too small re-decodes posters while scrolling back.

## 3. Suspects (what's known before measuring)

Each marked from M1's findings (§5): **confirmed**, **ruled out**, or still open. The TV is the one platform not yet measured.

### 3.1 Desktop player (mpv, `media_kit_engine.dart`)
- **The read-ahead buffer is 192 MB on desktop** (`_bufferBytes`, 64 MB on mobile), plus `cache-secs` 60 and `cache-on-disk`. Up to 192 MB of the 850 MB can be this, by design. **Confirmed, and twice that:** media_kit's `bufferSize` also sets the back buffer, and `cache-on-disk` doesn't keep it out of RAM, so ~300 MB of the 4K peak (finding 8).
- **Decoded 4K frames:** about 12 MB each (NV12), and mpv queues several, plus GPU copy-back (`vaapi-copy`) and the texture media_kit draws into. **Part of the peak, all given back:** the GPU mappings return to their start size after closing (finding 6).
- **Freed but not returned:** closing calls `player.dispose()` (`_release`), and a test checks no native player stays alive (`livePlayers`). But glibc keeps freed memory in its per-thread arenas for reuse, and mpv and FFmpeg use many threads. RSS would then stay high without a leak. The next video reuses it. **Confirmed: the main cause on desktop** (findings 2, 6, 9). No leak (heaptrack, finding 3).
- **media_kit_video's texture and GL objects** (`NativeVideoController`): whether they are freed on dispose is unverified. **Ruled out:** freed (heaptrack, finding 3; the GPU mappings, finding 6).

- **Found in M1, not a suspect before: NVIDIA's GL driver** allocates ~100 MB on a thread of its own about 10 minutes in, idle or not (finding 5). Not on Intel. Not ours to fix.

### 3.2 Phone and TV player (ExoPlayer, `exo_player_engine.dart`)
- Different engine, so nothing in §3.1 carries over. ExoPlayer's own buffer, MediaCodec's output surfaces, and video_player's texture. Android splits memory into Java heap, native, and graphics (`dumpsys meminfo`). Each needs its own check. **Phone: ExoPlayer's buffer (~150 MB Java) waits for a garbage collection after closing, and one collection frees it all** (finding 11). No leak. The TV is still to measure.

### 3.3 Images
- **Phone and desktop use Flutter's default image cache** (up to 100 MB, 1000 images). Nothing sets it. That may be the slow climb in §1.1. It should level off at the cap. **Confirmed: it is the climb, and it levels off at 100 MB** (findings 4, 9, 12). On the phone it costs ~2.6× that in graphics memory (finding 12).
- **The TV sets 150 MB at 2× and 250 MB at 4×** (`TvImage.sizeCache`, TV.md §9.1): *above* the default, on the weakest devices. Plus `hdUrl` originals on focus.
- **Decoded posters stay cached while a video plays.** They aren't needed then, and they compete with the player for RAM.
- `MediaImage` decodes at display width (`memCacheWidth`), which keeps each image small. Check that every image path uses it (seek previews, hero banners, the TV's HD swap).

### 3.4 Dart side
- Providers kept alive (14 files use `keepAlive` or `autoDispose`): a page's provider that never disposes, or a family that grows with every title opened. **Ruled out** (findings 14, 15).
- Streams, controllers, listeners and timers not cancelled when a screen or the player closes (`Timer.periodic` in `player_controller.dart` and `diagnostics.dart`). **Ruled out** (finding 15).
- `EventLog` and other in-memory buffers: check they are capped. **Ruled out: capped** (finding 15).

### 3.5 Downloads
- A long download (GBs) shouldn't hold growing buffers in memory. **Ruled out:** ~40–50 MB while it runs (finding 16).

## 4. How we measure

### 4.1 The cycle test (new: `integration_test/memory_test.dart`)
Through the real app and engine, live API:
1. Open the app, settle, record **before**.
2. Repeat 10 times: open a 4K title, play 60 s, record **playing**; close, wait 30 s, record **after close #n**.
3. Report each step as JSON (`test_driver/perf_driver.dart`, like the perf tests).

Each record: `ProcessInfo.currentRss`, Dart heap used and capacity (VM service `getMemoryUsage`, profile mode), `MediaKitEngine.livePlayers`, the image cache's `currentSizeBytes` and `liveImageCount`. On Linux add `/proc/self/smaps_rollup` (anonymous vs file-backed). On Android add `dumpsys meminfo <package>` (Java, native, graphics) from the driver side.

Run on: Linux (this PC), the Omarchy laptop, the phone (`flutter drive --profile`), the TCL TV, Windows if available.

### 4.2 The browse test
Scroll all of Home, open 3 genre pages and scroll each 10 pages, open 10 titles, then idle 10 minutes. Record every 30 s. Phone, desktop and TV.

### 4.3 The long-play test
20 minutes of 4K, RSS every 30 s. Includes a few seeks and a quality switch. Phone, desktop and TV.

### 4.4 Telling a leak from held memory
- **Grows every cycle:** a leak. Find which side: if Dart heap grows, take two heap snapshots (DevTools) and diff them. If only native grows, look at the engine (mpv handles, textures, ExoPlayer instances).
- **Rises on the first cycle, then flat:** held memory. On Linux, check by calling `malloc_trim(0)` after close: if RSS then drops, it's the allocator, not a leak.

### 4.5 In the field
`logEvent('memory', …)` with RSS when the player opens and 30 s after it closes, so the Activity log (Settings → Help) shows the pattern on a user's device. Twice per video, not every second.

## 5. Milestones

Each milestone ends with its numbers written here, and the plan corrected if a suspect turns out wrong.

### M0: Measuring tools
- [x] `integration_test/memory_test.dart`: the cycle test (§4.1), with the browse (§4.2) and long-play (§4.3) scenarios selectable by `--dart-define` (`MEMORY_SCENARIO`, `CYCLES`, `PLAY_SECONDS`, `LONG_MINUTES`, `IDLE_MINUTES`, `MEMORY_QUALITY`). Phone and TV UIs, as the device has it *(2026-11-25)*
- [x] The driver (`test_driver/memory_driver.dart`) writes each run's JSON to `build/memory/<device>-<ui>-<scenario>.json` and prints its table *(2026-11-25)*
- [x] A small summary script (`tool/memory_report.dart`): every sample, the peak, and PASS/FAIL against T1–T4 *(2026-11-25)*
- [x] Memory lines in the event log (§4.5): `MemoryLog` in `lib/core/diagnostics/memory.dart`, called by `PlayerController` when it opens, after 60 s of playback, when it closes, and 30 s later (that timer only once `startDiagnostics` ran, so no test is left with one) *(2026-11-25)*
- [x] AGENTS.md Commands: how to run it on Linux, the phone and the TV *(2026-11-25)*

*What the tools read (`readMemory`):* RSS and its peak (every platform); anonymous and file-backed parts (`/proc/self/smaps_rollup`, Linux and Android; what's left of RSS is shared memory, such as GPU buffers); the Dart heap, reserved heap and external memory (the app's own VM service, profile and debug builds, after a forced GC on the "closed" samples); the image cache; live mpv players; on Android `Debug.MemoryInfo` (Java heap, native, graphics, total PSS) through MainActivity's `memoryStats`.

*Smoke run (2026-11-25, this PC, EndeavourOS, NVIDIA, 2 cycles of 15 s):* start 570 MB, playing 1140 and 1165, closed 783 and 788. So +213 MB stays after the first close (T1 fails), and the second video added only +5 (T2 passes). Only a hint: M1 runs the full 10 cycles.

### M1: Investigation (every platform, every suspect)
Linux (this PC, and the Omarchy laptop):
- [x] Cycle test: before, playing, after each close (T1, T2). This PC *(2026-11-25)*, the Omarchy laptop *(2026-11-26, finding 9)*
- [x] Is the after-close memory the allocator? `malloc_trim(0)` experiment (§4.4): **mostly yes**, plus a small real leak *(2026-11-25)*
- [x] Find the two native growths with heaptrack (below): **no leak per video; the idle jump is NVIDIA's GL driver** *(2026-11-26)*
- [x] The idle jump on other GPUs: **none on the laptop's Intel GPU** (finding 9) *(2026-11-26)*. Optional: whether a driver setting stops it on NVIDIA (`__GL_THREADED_OPTIMIZATIONS=0`)
- [x] What trimming leaves above start (`/proc/<pid>/smaps` by mapping): **mostly malloc's, split over its arenas**; capping them at 2 keeps it flat *(2026-11-26)*
- [x] How much of the 4K peak is the 192 MB buffer? Run at 64 MB and compare: **~300 MB**, as media_kit uses it twice (finding 8) *(2026-11-26)*
- [x] Browse test (T3): the image cache levels off at its cap, 100 MB; something else jumps at idle (below) *(2026-11-25)*
- [x] Long-play test (T4): levels off *(2026-11-25)*

*Findings so far (2026-11-25, this PC: EndeavourOS, NVIDIA, the test build, 4K Endgame).* Runs: `build/memory/endeavouros-desktop-*-run1.json` (10 cycles, browse, long) and `*-trim.json` (6 cycles and browse, with `MEMORY_TRIM=true`). The test's RSS starts about 300 MB above the real app's (§6), so compare rows, not the system monitor.

1. **Closing doesn't give memory back (T1 and T2 fail).** Start 556 MB, 1,300–1,750 playing, 979 after the 1st close (+423), climbing to a plateau of ~1,155 from the 6th close to the 10th. File-backed memory goes back (516 playing, 378 closed, 337 at start: the +41 is libmpv and FFmpeg's code staying loaded). The Dart heap is ~53 MB after every close and no player stays alive: **nothing is kept on the Dart side.**
2. **Most of it is glibc keeping freed memory (§3.1, confirmed).** glibc's own count (`mallinfo2`): native code holds 476 MB while playing and 63 MB after the close, but glibc keeps **450–800 MB of freed memory** for reuse. `malloc_trim(0)` gives back 240–300 MB of RSS in 2 s: after the first video, 939 → 642 MB, +78 over start. **This justifies the M2 `malloc_trim` fix.** Trimming doesn't return all of it: freed space split into small pieces between live allocations can't be handed back.
3. **No leak per video (heaptrack).** glibc's in-use count after each close looked like a leak: 63, 66, 68, 78, 89, 99 MB (start 55). heaptrack says no. It recorded every native allocation in a 2-cycle and a 6-cycle run (`heaptrack_print -l -d`, the app stopped in the same closed state). After 6 videos the app held **8 MB less** than after 2, and nothing from libmpv, FFmpeg or media_kit was in the difference. What moved: Flutter's engine (−17 MB) and NVIDIA's driver (±3 MB), caches that rise and fall, and Wayland's event queue (+4 MB). media_kit's texture and GL objects are freed (§3.1, ruled out).
4. **Browsing: images level off at the cache's cap.** 100 MB, ~190 images, from the first genre page on: Flutter's default cap works, the climb in §1.1 isn't the image cache past its limit.
5. **But on idle Home, native memory jumps +100 MB, at the same moment in both runs** (about 10½ min after the app started, 7 min into the idle, then +20–40 again 3 min later). glibc's in-use count rises 74 → 173 MB: real allocations, not kept memory, and trimming doesn't return them. The Dart heap and the image cache don't change. Idle Home isn't still: its hero carousel moves on every 10 s (`home_hero.dart`). **heaptrack: it's NVIDIA's GL driver.** Comparing 10 idle minutes with 5: 107 of the 113 MB more comes from one of the driver's own threads (`libnvidia-eglcore.so`, every frame of the stack inside the driver, from the thread's start), in 1,597 allocations. No app, Flutter or mpv code is on that stack. So it's NVIDIA-only, not ours to fix in the app; the laptop's run says whether other GPUs do anything like it.
6. **What trimming leaves is mostly glibc's too, split over its arenas.** `/proc/<pid>/smaps` at each sample of 3 trimmed cycles (snapshots from outside the app, sorted by mapping):

   | MB, smaps | start | playing #1 | trimmed #3 |
   |---|---|---|---|
   | glibc's per-thread arenas | 20 | 389 | 118 |
   | glibc's main heap | 36 | 90 | 69 |
   | GPU memory mapped in (`/dev/nvidiactl`) | 55 | 184 | 53 |
   | libraries (NVIDIA, mpv and FFmpeg, the rest) | 262 | 306 | 298 |
   | Dart heap | 55 | 56 | 54 |
   | threads | 30 | 50 | 27 |

   About 130 MB stays in glibc's arenas, which trimming can't return: a few live allocations are spread over them. glibc gives busy threads their own arena (up to 8 per core), and mpv has many threads. The GPU memory goes back, no thread is left behind, and +36 MB is library code loaded once. **With `MALLOC_ARENA_MAX=2`**, after trimming: 623, 639, 629 MB (test's RSS) against 672, 696, 725 by default, so ~100 MB less and flat instead of creeping. Peak while playing barely changes (1,286–1,376 against 1,294–1,406). Without the trim, closing is the same either way (~925): the fix needs both. Unmeasured: whether fewer arenas cost playback smoothness (mpv's threads share the allocator's locks).
7. **4K playback levels off (T4, in spirit).** 1,550 MB by 2 minutes, a step up after each seek (mpv keeps the seeked-from range in its cache), flat over the last 5 minutes (1,705 → 1,700). T4 now measures the last 5 minutes (§2): +20 MB, just over, and all of it the step after the minute-15 seek (1,685 → 1,705), then flat for 4½ minutes (1,705 → 1,700). The test now seeks at minutes 5, 10 and 14, so the last 5 minutes have no seek in them. The quality switch dropped to 919 for the moment the old player was gone, then back up within 90 s.
8. **The buffer is about 300 MB of the 4K peak, because media_kit uses it twice.** `PlayerConfiguration.bufferSize` sets both mpv's read-ahead (`demuxer-max-bytes`) and its back buffer, what has already played, kept for seeking back (`demuxer-max-back-bytes`; media_kit 1.2.6, `real.dart`). So 192 MB is up to 384 MB, and `cache-on-disk` doesn't keep it out of RAM. 10 minutes of 4K at 64 MB (`*-long-buf64.json`) against 192 (`*-long-run1.json`): 1,227–1,282 MB playing in minutes 2–7 against 1,507–1,566 (−300), and 974 after closing against 1,149. Neither run logged a stall, but 64 MB is only ~15–25 s of 4K read-ahead. So for M2: keep the read-ahead, shrink the back buffer.

9. **The Omarchy laptop (Intel UHD, Raptor Lake; the test app built here and run over SSH; `build/memory/omarchy-desktop-*-trim.json`) shows the same, smaller.** Start 327 MB, 721–896 playing 4K (the ~850 in §1), ~690 after each close, and **~420 after trimming** (+93 over start): trimming gives back ~270 MB. Native memory in use returns to ~85 MB after every close (74 at start): no leak. glibc's kept memory grows every video, to 1.5 GB of address space by the 6th (mostly not resident): it spreads over more and more, which is what the arena cap stops. **Idle Home is flat** (377–388 MB for 10 minutes): no jump on Intel, so finding 5 is NVIDIA's alone. Browsing levels off with the image cache at its 100 MB cap.
10. **A measuring artifact, fixed (2026-11-26).** The samples that force a GC ("closed", the last idle one) read RSS after asking the VM for its allocation profile, which costs it 30–40 MB for a moment: their Dart heap reads 52–56 MB against 24–26 two seconds later. So every "closed" figure above is ~30 MB high, and the laptop's T3 "+44 MB, FAIL" is only that (without it: 377 → 384, a pass). The test now reads the process first.


*The phone (2026-11-26, OnePlus CPH2423, Android 15, ExoPlayer; `build/memory/oneplus-cph2423-*`: `-cycle-run1` 10 cycles, `-browse-run1`, `-long-run1`, `-cycle-gc` 4 cycles with `MEMORY_TRIM=true`).* Sizes are `Debug.MemoryInfo` (PSS) unless RSS is said.

11. **Closing the player gives nothing back until Java collects its garbage, and then it all comes back.** PSS 250 at start, 483 playing, 495 after closing; across 10 videos it levels at ~575 from the 5th (no leak). The **Java heap** stays at ~165 MB after closing (12 at start): ExoPlayer's 4K buffer (its default is 128 MB for video), let go but not yet collected. ART collects when the app allocates, and after closing the app hardly allocates Java objects. **One collection (`collectGarbage`, test only) takes the Java heap back to 12 MB:** PSS 491 → 350, and RSS 667 → 525. So nothing is held; it just waits. What's left above start after that grows ~16 MB a video for 4 videos (350, 377, 386, 398): graphics (60 → 170) and the image cache (12 → 58 MB, the player pages' artwork), which level off by the 5th video.
12. **Browsing: flat (T3 passes, +1 MB), but graphics memory is 2.6× the image cache.** The cache fills to its 100 MB cap by the first genre page and graphics goes 63 → 328 MB, then stays there for 10 idle minutes. On the phone a decoded image lives in GPU memory, and costs more there than the cache counts. So the image cache's cap is the biggest lever for the phone's browsing memory (M2, against P4 and P5).
13. **4K playback is bounded (T4 passes, +9 MB in the last 5 minutes).** PSS 459–527 MB playing: the Java heap saw-tooths 164–204 (the buffer filling and being collected) and native and graphics stay flat (66–74, 108). Much smaller than mpv's: ExoPlayer decodes in hardware into the texture, with no copy back.


*The Dart side (2026-11-26, this PC).*

14. **The Dart heap keeps nothing (§3.4, ruled out).** Each run's report now lists the classes that grew most from start to end, after a GC (VM service `getAllocationProfile`). After 5 videos the biggest is 154 KB of strings, then lists, records and semantics nodes: under 1 MB in all, the widgets of the screen on show. Likewise after the download.
15. **Nothing outlives its screen, and the buffers are capped (code read).** Every `.family` provider is `autoDispose`; paged lists stay 5 minutes after nothing shows them (`PagedMediaNotifier.keepFor`), by design, so going back doesn't reload. Every subscription, timer and listener is cancelled by its owner (both engines, `PlayerController`, `HomeHero`, audio focus, the TV screens); the few never cancelled belong to things that live as long as the app (the router, the downloader's updates). `EventLog` keeps 2,000 entries of at most 4,000 characters, and at most 20,000 lines waiting for the disk (a few MB with real lines). The downloads' per-task maps are emptied when a task is forgotten. There is no in-memory API cache.
16. **A long download costs ~40–50 MB while it runs, and keeps about that.** The 3.3 GB 1080p file (`*-download.json`) took 2 min 7 s: RSS 498 at start, 533–548 downloading, 546–581 over the next 7 idle minutes, 575 after deleting it. Native (glibc's in-use 47 → 70–77), not Dart (heap ~30 MB, external ≤ 7 MB while downloading). Small, and the M2 trim covers it. *A first run (`*-download-run1.json`) climbed +150 MB because the download restarted three times: the test gave the downloader a relative folder, which it reads from `/`, so every finishing copy failed and the retry started over from 0. Fixed in the test; the library behaviour behind it is in DOWNLOADS.md §3.7.*

*After #8 (2026-11-26, this PC, the cache in a real folder).*

17. **#8 took mpv's buffer out of RAM, so finding 8 was the cache file failing to open.** glibc's in-use count while playing 4K is ~255 MB now, against ~485 before #8: the packets go to mpv's cache file. RSS playing: 1,080–1,385 MB (`*-cycle-after8`, `*-long-after8`), against 1,300–1,750; after the first close +224 MB over start, against +423. It's the same with the folder in `/tmp` (`*-perf-tmpcache`): the file helps, not the disk. The trim after closing (fix 1) now finds little to give back: 31–36 MB in 9 ms, logged by the app; the test's own trim 30 s later gives 0 more. What stays after closing (start → closed #1, one run): anonymous +88 to +145 MB, of which glibc's in-use count is only +16 (the rest is mostly its arenas, which trimming can't return: fix 4), file-backed +54 (libmpv and FFmpeg's code), the image cache +11. **Over 20 minutes of 4K it still climbs** (1,128 → 1,385, T4 +50 MB in the last 5 minutes): each seek steps it up and nothing comes down. The buffer is in the file now, so the steps are glibc's: its in-use count 266 → 351 MB and its free memory 65 → 267.

Android phone (ExoPlayer):
- [x] Cycle test, with Java, native and graphics per step (`Debug.MemoryInfo`): closing gives nothing back until Java collects its garbage (finding 11) *(2026-11-26)*
- [x] Browse test: T3 passes; graphics memory is ~2.6× the image cache (finding 12) *(2026-11-26)*
- [x] Long-play test: T4 passes (finding 13) *(2026-11-26)*

TV (TCL, ExoPlayer, Skia):
- [ ] Cycle test, with `dumpsys meminfo`
- [ ] Browse test, with the 150/250 MB image cache, and again with Flutter's default, to compare
- [ ] Long-play test

Windows (mpv), if a machine is available:
- [ ] Cycle test

Dart side, on any platform:
- [x] What grew in the Dart heap, by class, from start to the end of a run (every run's report now lists it): **under 1 MB** (finding 14) *(2026-11-26)*
- [x] Providers, listeners and timers that outlive their screen (§3.4): **none** (finding 15) *(2026-11-26)*
- [x] EventLog and other buffers are capped: **yes** (finding 15) *(2026-11-26)*
- [x] A long download: memory over 10 minutes (§3.5): ~40–50 MB, and an edge case for DOWNLOADS.md §3.7 (finding 16) *(2026-11-26)*

Close the milestone:
- [ ] Write the findings into §3 (confirmed or ruled out) and the targets into §2
- [ ] Decide which of the M2 items to do, and add any new ones

### M2: Fixes (only those M1 justifies, each checked against §2.1)
- [ ] **The performance baseline first**, before any change, on this PC, the laptop, the phone and the TV: P1–P5 (§2.1). Measured by the memory test's `perf` scenario (`PlayerEngine.frameStats`, stall watch, timed open, seeks and return) and the perf tests. This PC, the laptop and the phone done *(2026-11-26)*; the TV to do

  *The baseline (before M2; medians of 3 rounds; 4K Endgame; times in ms):*

  | Device | start | seek −10 s | −30 s | +10 s | +5 min | return | dropped / late frames | stalls |
  |---|---|---|---|---|---|---|---|---|
  | This PC (NVIDIA) | 1,341 | 105 | 574 | 475 | 520 | 101 | 0 / 0 | 0 |
  | Omarchy laptop (Intel) | 1,820 | 157 | 368 | 416 | 585 | 102 | 0 / 0 | 0 |
  | Phone (CPH2423, ExoPlayer) | 3,847 | 1,081 | 2,007 | 1,491 | 1,344 | 100 | – | 0 |
  | This PC, after #8 (afternoon) | 3,026 | 109 | 579 | 470 | 1,680 | 101 | 0 / 0 | 0 |

  *This PC after #8:* start and the +5 min seek are slower, but **mostly the network**, not #8: alternating the old RAM cache (`cache-on-disk=no`) with the cache file the same afternoon, twice each (`*-perf-ramcache1,2`, `*-perf-filecache1,2`), start took 2,067–3,620 ms with RAM (mean 2,715) and 2,680–3,850 with the file (mean 3,332), and +5 min 1,301–2,564 against 1,100–2,615. So the file may cost ~600 ms at start, inside today's noise; the −10 s seek was ~150 ms in 4 of 6 file rounds (104–110 with RAM), within the morning's 105–161. Neither dropped a frame or stalled. **To settle: the same alternation on a quiet connection** (a morning, as the first baseline). Until then compare each fix against runs taken alongside it, alternating with and without it, as fix 1 did.

  *start*: opening to playing. *Seeks*: until it plays from the new place (only −10 s is near-instant: the others are mpv decoding from a keyframe, so the back buffer matters for −10 s most). *return*: closing until the page's images are drawn; 100 ms is the measurement's floor, so nothing was re-decoded. Runs: `build/memory/*-perf.json`.

  *UI frame times, this PC* (`player_perf_test`, `build/memory/baseline-pc-player_perf.json`; UI thread, raster thread, ms):

  | Scene | UI p90 / p99 | raster avg / p90 / p99 | raster over 8.3 ms |
  |---|---|---|---|
  | 4K, controls up | 0.12 / 0.49 | 7.8 / 34.8 / 36.2 | 21.8% |
  | controls fading | 0.13 / 1.43 | 7.7 / 34.7 / 37.7 | 22.6% |
  | scrubbing with previews | 0.53 / 1.42 | 11.4 / 34.6 / 35.1 | 36.9% |
  | quality menu | 0.33 / 1.60 | 6.2 / 32.9 / 36.2 | 17.3% |

  The raster thread's p90 of ~34 ms over 4K is today's state on this PC (NVIDIA): a fix must not raise it. `scroll_perf_test` runs on the phone only (its layout).

  *UI frame times, the phone* (`player_perf_test` and `scroll_perf_test`, `build/memory/baseline-phone-*.json`; 120 Hz, 8.3 ms budget):

  | Scene | UI p90 / p99 | raster p90 / p99 | over budget (UI, raster) |
  |---|---|---|---|
  | 4K, controls up | 0.80 / 2.58 | 5.36 / 7.22 | 0.3%, 0.3% |
  | controls fading | 1.98 / 5.03 | 5.30 / 7.42 | 0%, 0.2% |
  | scrubbing with previews | 0.76 / 0.97 | 3.89 / 4.53 | 0%, 0% |
  | quality menu | 1.88 / 7.23 | 4.88 / 6.60 | 0.6%, 0.1% |
  | Home scrolling | 2.68 / 8.95 | 4.97 / 6.99 | 2.0%, 0.4% |
  | a grid flung deep | 2.08 / 4.65 | 5.34 / 6.65 | 0.1%, 0.1% |
  | a title opened and closed | 1.28 / 9.03 | 5.05 / 6.79 | 1.3%, 0.3% |

  *The phone's video itself (P1):* video_player doesn't report ExoPlayer's dropped frames, and this phone's Android records no freeze or judder metrics for a decoder session (`dumpsys media.metrics` has only the basics: 24 fps, one flush per seek). `tool/tv_cadence.sh` doesn't help in the test build, which draws every frame. So on the phone P1 is the stall count (0), the frame times above, and the owner's eye, as in PLAYER.md §13. The phone's seeks are slower than desktop's (ExoPlayer re-buffers from the new place): −30 s at ~2 s is right at PLAYER.md §1's target.
- [x] Leaks found in M1, each fixed: **none found** (findings 3, 11, 14) *(2026-11-26)*

**The fixes, one at a time, lowest risk first** (owner's go-ahead, 2026-11-26). Each one: make the change, re-run its memory scenario and the `perf` scenario and perf tests on the devices it touches, compare with the baseline above, and keep it only if no P1–P5 number got worse beyond the run-to-run noise (§2.1). Write the before and after into its box.
1. - [x] **Linux: `malloc_trim(0)` after the player closes** (FFI in `media_kit_engine.dart`, off the UI thread, e.g. `Isolate.run`; never while a video plays). Expected: closing gives back ~250 MB (findings 2, 9). Check: `cycle` with T1/T2, `perf`. *Done, kept (2026-11-26, this PC):* `NativeHeap` (`lib/core/platform/native_heap.dart`) trims in a background isolate **10 s after the last player is disposed**, since media_kit destroys mpv only 5 s after `dispose()`; a new player cancels it. **It gives back 31–36 MB in 9 ms**, not ~250: #8 already moved the buffer out of the heap (finding 17). T1: +161 to +211 MB over start in three short runs (`*-cycle-fix1`), against +224 without. Performance, alternating with and without it (`*-perf-fix1-1,2`, `*-perf-nofix1-1,2`; medians, ms): start 3,010 and 3,147 against 3,055 and 3,207; −10 s 104 and 154 against 107 and 108 (154 shows up without it too: the baseline note above); −30 s 578, 578 against 572, 579; +10 s 469, 474 against 475, 519; +5 min 1,839, 1,414 against 1,936, 1,939; 0 dropped, late or stalled. No cost, so it stays. To re-check on the laptop, where trimming gave back more (finding 9)
2. - [ ] **Android: one Java garbage collection after the player closes** (a background thread in `MainActivity`, never during playback; the test-only `collectGarbage` shows it frees the ~150 MB ExoPlayer's buffer leaves, finding 11). Check: the phone's `cycle`, `perf` (P2, P5), `player_perf_test`
3. - [ ] **Desktop: a smaller back buffer.** *Moot on desktop since #8 (finding 17): the back buffer is in mpv's cache file now, not RAM. Still to decide for phones and TVs, where the cache stays in RAM.* Keep the 192 MB read-ahead (`bufferSize`) and set `demuxer-max-back-bytes` on its own to ~32 MB, after media_kit sets it (finding 8). The −10 s seek must stay ~100–160 ms (only it uses the back buffer). Expected: ~250 MB less while playing 4K. Then decide the same for phones and TVs (64 MB). Check: `long`, `perf`, `player_perf_test`
4. - [ ] **Linux: cap glibc at 2 arenas** (*now desktop's main lever: after #8 and the trim, most of what stays after closing, and the 20-minute climb, is in glibc's arenas, finding 17*) (`mallopt(M_ARENA_MAX, 2)` at start via FFI, or `MALLOC_ARENA_MAX=2` in AppRun). The riskiest for playback: mpv's threads share the allocator's locks. Expected: ~100 MB less after closing, and flat across videos (finding 6). Check hardest: `perf` (dropped, late, stalls), `player_perf_test`, `long`
5. - [ ] **The phone's image cache cap** (graphics memory is ~2.6× the cache, finding 12), and the TV's (its 150/250 MB caps, §3.3) once the TV is measured. Check: `browse`, `scroll_perf_test`, `perf` (P5: the return to the page)
6. - [ ] Maybe: free decoded posters while a video plays (`imageCache.clear()` on opening the player), only if 5 isn't enough and P5 holds

### M3: Proof
- [ ] Every M1 test run again on each platform, the results in a table here, against T1–T5
- [ ] The owner checks on the Omarchy laptop: the app's memory drops after closing a 4K video
- [ ] The owner checks on the phone and the TV
- [ ] PLAYER.md and TV.md updated with any changed buffer or cache size, and their reasons

## 6. Risks
- **RSS isn't everything.** GPU memory on desktop (NVIDIA) may not show in RSS, and on Android graphics memory is separate. Record what each platform can see, and say what it can't.
- **The test binding draws more frames than the real app** (TV.md §9). Memory is less affected than frame times, but confirm the headline numbers in the real app with the Activity log lines (§4.5).
- **Shrinking buffers trades memory for smoothness.** Any buffer change re-runs the player perf tests and `tool/tv_cadence.sh`.
