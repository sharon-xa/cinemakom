# Cinemakom (Flutter): Build Plan

**Goal:** rebuild the Cinematy Android app (Kotlin/Jetpack Compose, `../cinematy`) as one Flutter codebase for **Android (and Android TV), Linux and Windows**. Apple platforms (iOS, iPadOS, macOS, tvOS) were dropped on 2026-11-22 (owner's decision). The app is a frontend for the Cinemana API (see [`API.md`](API.md)). There is no backend work.

**Scope**
- Match every feature of the Kotlin app.
- Add the features that the newly found endpoints make possible.
- Leave out anything that needs a Shabakaty account (server-side history, likes, comments, subscriptions). It stays out of scope unless we decide to add sign-in later.

---

## 1. Prerequisites

| Item | Notes |
|---|---|
| Flutter SDK | ✅ The project is pinned to **Flutter 3.47.9** (Dart 3.13) in `.fvmrc`, so use `fvm flutter …`. The global `stable` (3.50.0) has an NVIDIA Linux rendering bug (see AGENTS.md → Commands) |
| Java | ✅ OpenJDK 17 at `/usr/bin/java` (needed by the Android Gradle build) |
| Android | ✅ SDK at `~/Android/Sdk` (with cmdline-tools), emulator `Medium_Phone_API_37.0`. `flutter doctor` is green. The new Android CLI no longer needs a license step |
| Linux | ✅ `clang cmake ninja-build pkg-config gtk3` and **`mpv`/libmpv** (needed by media_kit). On Arch: `sudo pacman -S mpv` |
| Windows | Visual Studio 2022 with the "Desktop development with C++" workload. media_kit ships its own libmpv |

The project was created with (done, kept for reference):
```bash
cd ~/Projects/flutter/cinemakom
fvm flutter create --project-name cinemakom --org io.github.sharon_xa --platforms android,ios,linux,windows .
```
> ✅ Application ID: **`io.github.sharon_xa.cinemakom`**, based on the GitHub account `sharon-xa`. Hyphens aren't allowed in IDs, so `-` becomes `_`. **Never change it after the first store release.**

---

## 2. Tech stack

| Concern | Kotlin app | Flutter choice | Why |
|---|---|---|---|
| State management and DI | Compose state / ViewModels | **flutter_riverpod** | Testable and handles async state well. No codegen needed to start |
| Navigation | Manual state in MainActivity | **go_router** (with `StatefulShellRoute` for tabs) | Deep links, back-stack per tab, and desktop back handling |
| HTTP | Retrofit + OkHttp + Gson | **dio** | One interceptor adds the required headers. Also gives timeouts, cancellation and retry |
| JSON | Gson with lenient fallbacks | **Hand-written tolerant parsers** (`dart:convert`) | The API changes key names across endpoints, so generated `fromJson` breaks. Port `parseMediaItems`, `parseCategories`, `parseSeriesEpisodes` and `parseSubtitles` |
| Immutable models | Kotlin data classes | **Plain immutable classes** (`final` fields, `const` constructors) | No freezed, so no codegen for models |
| Images | Coil | **cached_network_image** | Accepts `httpHeaders`. Its cache uses sqflite, so **desktop needs `sqflite_common_ffi`** (see §6) |
| Video player | Media3 ExoPlayer | **media_kit** + media_kit_video | The only mature player that covers all four platforms. Supports per-media HTTP headers, external subtitles and quality switching |
| Local database | Room v4 (downloads, history, favorites) | **drift** (sqlite3 3.x) | Typed SQL, reactive streams, and it works on desktop. sqlite3 3.x bundles SQLite through build hooks. **Don't add `sqlite3_flutter_libs`**: it is end-of-life |
| Key-value settings | SharedPreferences | **shared_preferences** | |
| Downloads | Android DownloadManager | **background_downloader** | Android, Windows, Linux. Custom headers, pause/resume, progress and notifications |
| Localization | Inline ar/en strings | **flutter_localizations + intl (ARB files)** | English is the default. Arabic is fully supported, and the layout must work in RTL |
| Paths | Android external storage | **path_provider** | |
| Player extras | Android APIs | `screen_brightness`, `volume_controller` (mobile), `wakelock_plus`, `window_manager` (desktop fullscreen) | |
| Material / Cupertino | `package:flutter/material.dart` | **material_ui**, **cupertino_ui** | Flutter 3.47+ moved Material and Cupertino out of the SDK. Import `package:material_ui/material_ui.dart`. `GlobalMaterialLocalizations` / `GlobalCupertinoLocalizations` now come from these packages, not `flutter_localizations` |
| Lints and tests | — | `flutter_lints` (or `very_good_analysis`), `flutter_test`, `mocktail`, `integration_test` | |

---

## 3. Architecture

Organized by feature, in layers: **data → domain → presentation**, with Riverpod providers connecting them.

```
lib/
  main.dart                     # bootstrap: MediaKit.ensureInitialized, sqflite ffi on desktop, ProviderScope (retry: noRetry)
  app/
    app.dart                    # splash until startup is done, then MaterialApp.router; locale, theme and RTL from settings
    router.dart                 # go_router: /welcome, the 5-tab StatefulShellRoute, and the per-tab browse routes
    navigation.dart             # openTitle / openGenre / openList: push a page inside the current tab
    catalog_providers.dart      # apiLanguageProvider, genresProvider, categoryLanguagesProvider
    splash_screen.dart          # mark + BulbLoader, retry when startup fails
    shell/app_shell.dart        # bottom bar / rail / extended rail by width (Breakpoints)
    widgets/                    # shared UI: TabPage, SubPageHeader/BackPill, MediaImage, PosterCard, MediaRow/SourceRow,
                                # PagedGridSlivers, ErrorView, SectionHeader, Segmented/FilterPill, BulbLoader,
                                # showChoicePicker, media_text.dart (titles, metadata, durations, episode labels)
    brand/                      # CinemakomMark / CinemakomLogo, brand_paths.g.dart (generated)
    theme/                      # the one Marquee theme: colour tokens, type scale, ThemeData
    l10n/                       # app_ar.arb, app_en.arb (+ generated app_localizations*.dart)
  core/
    network/
      api_client.dart           # Dio instance, base URL, header interceptor, logging
      api_endpoints.dart        # every path from API.md as builder functions
      api_exception.dart
      api_providers.dart        # Riverpod provider for the shared ApiClient
    json/
      json_utils.dart           # firstNonBlank(), parseIntLoose(), unescapeUrl()
    storage/
      database.dart             # drift DB (schema 2): watch_history, favorites, continue_hidden; downloads in Phase 6
      preferences.dart          # language, default resolution, default subtitle
    platform/
      platform_info.dart        # isDesktop / isMobile / isAndroid helpers
    downloads/
      downloader.dart           # Downloader interface (tests use test/helpers/fake_downloader.dart)
      background_file_downloader.dart  # the only file that imports background_downloader
    player/
      player_engine.dart        # PlayerEngine interface (tests use test/features/player/fake_engine.dart)
      media_kit_engine.dart     # the only file that imports media_kit: mpv options, headers, errors
      subtitle_fonts.dart       # the bundled libass font, copied to disk on desktop
  data/
    models/                     # MediaItem, MediaDetails, Episode, VideoSource, SubtitleTrack,
                                # Category, Language, StaffMember, StaffPage, VideoGroup, SkipRange
    parsers/                    # tolerant parsers ported from MediaModels.kt
    paging/
      media_sources.dart        # MediaSource: one class per paged list (genre, catalog, latest, featured, group, search)
      paged_media.dart          # pagedMediaProvider: loads a source page by page, de-duplicates, kept 5 min after use
    repositories/
      catalog_repository.dart   # home rows, groups, featured, latest, genres, by-category(+language), FAQ
      search_repository.dart    # base64 title search + AdvancedSearch, merged, de-duplicated and ranked
      media_repository.dart     # details, episodes, seasons, streams, subtitles, related, skip ranges, getVideosByIds, staff pages
      status_repository.dart    # cinemanaHealth(): public status page, asked only after API calls fail
      library_repository.dart   # favorites + continue watching (drift)
      download_store.dart       # the drift downloads table (MemoryDownloadStore for tests)
      downloads_repository.dart # queue, subtitles, events, fresh-URL resume, offline lookups
  features/
    home/  search/  genre/  details/  browse/ ("See all")  onboarding/ (language picker)  settings/
    player/                     # player_screen, player_controller (session, recovery), player_state,
                                # quality, subtitles, widgets/ (controls_overlay, seek_bar, subtitle_layer)
    library/                    # Library tab, Continue cards (Home uses them too), Favorite buttons
    downloads/                  # Downloads tab, a series' episodes, Download buttons and menus
    staff/                      # person page (actor, director, writer)
    faq/                        # to come
    debug/                      # debug-build-only API check screen (Phase 1)
      # each: <feature>_screen.dart, widgets/, <feature>_providers.dart
test/
  fixtures/                     # captured real JSON responses, one per endpoint
  parsers/                      # parser unit tests run against fixtures
  repositories/                 # tests against a fake ApiClient (fake_api_client.dart)
  helpers/app_harness.dart      # pumpApp() + fixtureApi(): the whole app on fixtures, no network, no images
  data/  features/  core/       # paging, screen and settings tests
integration_test/
  api_debug_test.dart           # live check of every endpoint
  player_engine_test.dart       # live check of PlayerController on the real MediaKitEngine
  player_test.dart              # the player end to end: movie (play, seek, quality, leave, resume), episode (Next)
  screenshots_test.dart         # drives the real app (live API) and saves PNGs of the main screens
```

Key rules:
- Only `core/network` knows URLs and headers. Screens never call Dio directly.
- All JSON handling goes through `data/parsers`. Repositories return clean domain models, and parsers never throw on bad input. They skip it.
- **Image, video and download requests reuse the same header map** (`ApiClient.defaultHeaders`). Keeping it in one place stops the four call sites drifting apart, which was the problem in the Kotlin app.

---

## 4. Features

Product rules (AGENTS.md): **zero censorship** (always the unrestricted level, no parental features) and **no ratings of any kind** (no scores, no likes, no "Top rated", no rating filters). Every feature below is backed by an endpoint verified in `docs/API.md`.

### 4.1 Core
- [x] **App shell:** five tabs: **Home, Search, Library, Downloads, Settings**. Bottom `NavigationBar` below 600 dp width, `NavigationRail` at 600 dp and up, extended rail with the logo at 1200 dp and up. The active tab has a pill indicator (`docs/DESIGN.md` §5).
  - *Decision (2026-11-19):* Search gets its own tab, and Continue watching and Favorites share the Library tab. This replaces the earlier Continue and Favorites tabs; Continue watching also stays a Home row.
- [x] **Home:** hero carousel from `banner` (wide covers), curated video groups, Featured, Latest movies, Latest series, Most watched (`views_desc`), New releases by year (`r_desc`), Recently added (`desc`), and genre rows. Load the above-the-fold sections first and the rest after.
- [x] **Genre detail:** infinitely scrolling grid (30 per page, offset paging that stops on a short page) with sort, kind (movies or series) and audio-language chips. Use `fallbackGenres` when the genre lists fail to load.
  - Sorts: recently added, oldest added, newest release, oldest release, most watched, **A→Z and Z→A**.
  - *Decision (2026-11-19):* A→Z / Z→A appear **only on genre pages**; the "All movies/series" lists don't offer them, because the catalog ignores title sorts (`SortOrder.worksOnCatalog`).
- [x] **Search:** 400 ms debounce, three requests in parallel (title search, AdvancedSearch movies, AdvancedSearch series), merged, de-duplicated and ranked. Never send an empty query. The year range is computed.
  - *Decision (2026-11-19):* search also matches **cast and crew names**, like the website (`staffTitle` = the query), with title matches ranked first.
  - *Decision (2026-11-19):* before you type, the Search tab shows a genre grid. Results show the title grid (titles also match by cast or crew name; there is no People row, DESIGN.md §8).
  - *Decision (2026-11-19):* **recent searches** above the genre grid, on the device only (`searchHistoryProvider`, a JSON list in the preference store): up to 10, newest first, no duplicates, an ✕ per row and "Clear all". Only searches the user meant are saved (the keyboard's search key, a recent search, or a title opened from the results), never the ones made while typing. DESIGN.md §8.
- [x] **Details** (a full page inside the current tab on every platform, two columns on desktop): poster, synopsis, year, duration, genres, audio languages, trailer (`trailerYoutubeId`), external link, season and episode picker. Add to favorites, download.
  - *Done in Phase 3 except:* Play (Phase 4), Favorite (Phase 5) and Download (Phase 6). Until Phase 4, Play is shown disabled and the hero's Play opens the details.
  - Label the external link "IMDb" only when `imdbUrlIsImdb`; anime links go to MyAnimeList.
  - *Decision (2026-11-19):* Details is a page, not a bottom sheet, so related titles and actor pages can stack and the back gesture steps through them.
  - Episodes show as "Episode N" from `Episode.numbering`: "Episodes 7 & 8" for double episodes, a "Final" badge for finales. Never use episode titles. Use the season image.
  - *Decision (2026-11-19):* **long seasons** (One Piece is one season of 1,179 episodes) are split into blocks of 50 (`episodeBlockSize`) picked with range chips, so cast and "More like this" stay in reach. The list opens on the block of the episode playing or watched last. The number column fits the widest number in the block, so 3- and 4-digit numbers stay on one line. The player's episode panel shares the list. DESIGN.md §5.
- [x] **Player** (full plan: [`PLAYER.md`](PLAYER.md)). *Done 2026-11-19 (M0–M9, PLAYER.md §15), on Android and Linux; Windows still to run:*
  - quality selection (default from settings, closest match).
    - *Decision (2026-11-19):* **2160p is treated like any other quality**, so "highest" picks 4K when a title has it, even on mobile data. Show the quality in the player so users know (4K is about 10 GB per hour): it is an always-visible chip in the player's top bar.
  - subtitles (Arabic, English or off, default from settings; one plain track per language, SRT preferred)
    - *Decision (2026-11-19):* anime titles with a styled ASS track also get **"Arabic (styled)"** as an extra choice. Plain Arabic stays the default. Ship one Arabic fallback font for libass. Downloads save the plain file, plus the styled one if it was chosen.
  - playback speed
  - aspect/fit modes
  - double-tap seek (mobile)
  - next episode
  - resume from saved position
  - brightness and volume swipe gestures (mobile only)
  - always fetch stream URLs right before playing (`MediaRepository.streams`, which refreshes stale ones); on a 403, fetch them again
  - when the API fails, ask `StatusRepository.cinemanaHealth()` once. If Cinemana is reported down, say so instead of blaming the connection (*decision 2026-11-19*)
- [ ] **Library tab:** a [Continue watching | Favorites] segmented control (`lib/features/library`). *Built 2026-11-19, to check on the phone.*
- [ ] **Continue watching:** progress saved to drift on pause, exit and every N seconds. Resume episodes using the series, season and episode fields. *Built 2026-11-19, to check on the phone.*
  - A finished episode shows the next one as "Up next", on Home and in the Library (`continueEntriesProvider`). After a series' last episode it leaves the list.
  - *Decision (2026-11-19):* a long press (or right click) offers **Remove from Continue watching**. It only hides the title (`continue_hidden` table) until it's watched again; the watch history and the episodes' watched marks stay.
- [ ] **Favorites:** add, remove and list. *Built 2026-11-19, to check on the phone.* A bookmark (not a heart, so it can't read as a like; *decision 2026-11-19*): a pill on Details, an icon button on the Home hero. Stored in the drift `favorites` table, the last added first.
- [ ] **Downloads:** video plus subtitle, live progress and speed, files grouped by series, delete, offline playback with the local subtitle file. When a long download gets a 403 (expired signed URL), fetch a new URL and resume. *Built 2026-11-19, to check on the phone.*
  - *Decisions (2026-11-19):* the quality is asked each time, with file sizes. Series get a button per episode and **Download season**. Downloads use any network (no Wi-Fi-only setting). Each download also saves the plain Arabic and English subtitles, and the styled one where the player draws it (not Android). At most 2 run at a time.
- [x] **Settings:**
  - language (English or Arabic, default English. Arabic flips the layout to RTL)
  - default resolution (2160p/1080p/720p/480p/360p, default 1080p)
  - default subtitle (Arabic, English or Off, default Arabic)
  - screen rotation, phones and tablets only (Portrait only, default, or Rotate with device, which follows the system auto-rotate; decision 2026-11-19)
- [x] **First-launch language picker:** the first time the app opens, ask the user to pick English or Arabic before showing Home. Save the choice. It can be changed later in Settings.
- [x] **Branding:** the Marquee logo (ticket stub carrying ك, `docs/DESIGN.md` §7), app icons for all platforms (including Android TV `tv_banner.png`), and the native splash screens, all generated by `tool/brand/generate.py`. The in-app splash (mark + `BulbLoader`) is done too. *Still to do: installing the Linux .desktop file and icons (Phase 8 packaging).*
- [ ] **Android TV / Google TV** ([`TV.md`](TV.md)): a separate TV UI (`lib/tv`) driven by the remote, with top tabs and a focus system that can't trap. The first attempt (2026-11-20) patched the phone UI and left focus traps (downloading an episode was impossible); it was reverted the same day, keeping the groundwork: Leanback launcher, banner, `isTv`. Every TV screen is designed (2026-11-20) on the TV page of the design canvas, with the chosen layouts in TV.md §2; sharp artwork on 4K panels is TV.md §9.1. **TV-0 ✅** (2026-11-20, checked on the TCL and the phone: TV entry in landscape, banner with the name, remote keys, phone starts upright; the TV draws apps at 960 × 540 dp ×2). **TV-1 ✅** (2026-11-20): the focus system in `lib/tv/focus`, with a test per rule and the no-trap check in English and Arabic. **TV-2 ✅** (2026-11-20, checked on the TCL): the tab shell and Back ladder, first launch, Home, genre pages and See all, sharp artwork. **TV-3 ✅** (2026-11-20, checked on the TCL): Details with the two-pane episodes, the person page, the download panels with the free-space check. **TV-4** (the player) and **TV-5** (Search, Library, Downloads, Settings): code and tests done 2026-11-20; the owner's check on the TCL is 40 of 61 lines in (2026-11-22, [`TV_CHECK.md`](TV_CHECK.md)), with its fixes committed. **TV-6** (polish): the performance test ran on the TCL (2026-11-21), which moved TVs to Skia (TV.md §9). *Next: the rest of TV_CHECK.md (§9 Library onwards, and the open lines in §1, §4, §6), then tick TV-4/5/6.*

### 4.2 Extras the API supports
- [x] **More like this** on details, from the recommendation service (`recommend.shabakaty.com`: same franchise, then shared cast), falling back to `relatedVideos`.
- [x] **Cast and crew** row on details (`actorsInfo`, `directorsInfo`, `writersInfo`). Tapping a person opens an **actor/director page** (`staff/actorID/...`): photo, name, role and title count, then a poster grid of every title they're credited on (`StaffScreen`, `openPerson`, route `person/:id` in every tab). *Done 2026-11-19.*
- [x] **Skip intro** button in the player, from `introSkipping` (`MediaDetails.introRanges`), which can hold two ranges.
- [x] **Seek-bar previews** from `video_thumbnails` sprite sheets (`SeekPreview.frameAt`). Popular titles have them; hide the preview when a title has none.
- [ ] **Season picker** that loads first (`videoSeasonNumber`), with episodes loaded per season.
- [x] **"See all"** page for each video group (`videoListPagination`).
- [x] **Genre × language filter** (`categoryLangFreqVideo` + `videosByCategoryAndLanguage`), e.g. Anime = Animation (57) × Japanese.
- [ ] **Advanced search filters:** kind, genre (`category_id`), year range, actor or director name (`staffTitle`). No rating filter, no sort (the server ignores it).
- [ ] **Library refresh:** update favorites and history metadata with `POST getVideosByIds` (40 numeric IDs per request). Once per session, when the Library tab opens (`libraryRefreshProvider`); a failure keeps what's stored. The answer has no genres, so a favorite keeps the genre it was saved with. *Built 2026-11-19, to check on the phone.*
- [ ] **FAQ / help** screen in Settings (`faqQuestion`).

### 4.3 Not possible or excluded
- **Comments:** switched off server-wide (`showComments: false` everywhere).
- **Collections and franchises, "Popular" (`popularFilms`), season posters:** the endpoints return nothing or fail with 500.
- **View counts:** `videoViewsNumber` is always 0.
- **Ratings, likes, age ratings:** excluded by the no-ratings rule.
- **Parental filtering, scene skipping, kids mode:** excluded by the zero-censorship rule.
- **Anything that needs a Shabakaty login.**

---

## 5. Phases

> **Status (2026-11-19):** Phases 0 and 1 are done, including the second API deep dive (`docs/API.md` is complete, and the product decisions it raised are recorded in §4). The design system, logo, app icons and the screen designs are done too (`docs/DESIGN.md` §8 and the design canvas). Phases 2 (app shell) and 3 (browsing) are done. **Phase 4 (player) is done** (M0–M9, PLAYER.md §15; Windows not run yet). **Phases 5 (library) and 6 (downloads) are built, to check on the phone.** The project runs on Flutter 3.47.9 through fvm (see AGENTS.md → Commands).

Each phase ends with something that runs. **Every phase is tested on Android and Linux.** Windows is tested from Phase 4 on.

### Phase 0: Setup ✅ *(done 2026-11-19)*
- [x] Fix the Flutter install, run `flutter doctor`, then `flutter create` (§1).
- [x] Add dependencies, lints and the folder layout from §3. `git init`. Write a `CLAUDE.md` or README that points to `docs/`.
- ~~Optional: CI~~ Skipped by decision. Run `fvm flutter analyze` and `fvm flutter test` locally.
- [x] **Done when:** an empty app runs on Android and Linux. Checked on the `Medium_Phone_API_37.0` emulator and the Linux desktop.

### Phase 1: Data layer *(most important)* ✅ *(done 2026-11-19)*
- [x] `ApiClient` with the headers, a 30 s timeout and a debug logger. Large responses are decoded on a background isolate.
- [x] Write `api_endpoints.dart` covering every public endpoint in `API.md`.
- [x] Port the tolerant parsers, and add the new models (staff, intro ranges, languages, FAQ, seek previews). Comments are switched off server-wide, so they aren't modeled.
- [x] Write `tool/capture_fixtures.dart`, a script that calls each endpoint once and saves the JSON to `test/fixtures/` (signed-URL credentials redacted).
- [x] Unit-test every parser against the fixtures, including edge cases (string vs number IDs, `\/` URLs, the `episodeNummer` spelling, object vs array roots).
- [x] Repositories (catalog, search, media) with fake-client tests. Staff pages live in `MediaRepository`.
- [x] **Done when:** `fvm flutter test` is green and a debug screen lists real data from every endpoint. Run the live checks with `fvm dart run tool/api_contract_check.dart` and `fvm flutter test integration_test/api_debug_test.dart -d linux`.
- [x] **API deep dive (2026-11-19):** reverse-engineered from the website bundle, its network traffic, a field survey and edge probes. This corrected the sort codes, the search encoding, the batch limit, banner images, paging end and episode titles. See `docs/API.md`.
- [x] **Second API deep dive (2026-11-19):**
  - **Sources:** every guest page of the website, the full bundle, the Android app 5.3.3 (read-only) and a 2,000-request field survey.
  - **New behaviour in the code:** `episode_flag` labels (finales, double episodes); styled ASS subtitles; stale stream URLs refetched past the API cache; sprite sheets with real row counts; placeholder images rejected; banner episode links; seasons fallback.
  - **Search and sorting:** `AdvancedSearch` needs `type` and ORs title and staff; title and release-date sorts.
  - See `docs/API.md` §8 for the product decisions this raised.

### Phase 2: App shell ✅ *(done 2026-11-19)*
- [x] go_router with the tab shell and per-tab back stacks (`lib/app/router.dart`, `StatefulShellRoute.indexedStack`). Tapping the active tab returns it to its first screen.
- [x] The single Marquee theme (`lib/app/theme/`), bundled fonts, and the ARB setup in en and ar with generated `AppLocalizations`.
- [x] RTL switching: the locale and theme come from the settings, so a language change applies live.
- [x] In-app splash: the mark with the marquee-bulb loader (`BulbLoader`, `docs/DESIGN.md` §4), shown while `appStartupProvider` loads, with a retry if startup fails.
- [x] First-launch language picker (English or Arabic), shown once before Home and saved to preferences. It starts on the device language and previews the pick live.
- [x] Preferences (`lib/core/storage/preferences.dart`: `settingsProvider` on shared_preferences) and the Settings screen. The Questions and answers row comes in Phase 7, the app version in Phase 8.
- [x] Responsive navigation: bar below 600 dp, rail from 600, extended rail with the logo from 1200.
- [x] **Done when:** a fresh install asks for the language, you can switch tabs, change the language live, and settings survive a restart. Checked by the widget tests, `integration_test/screenshots_test.dart` on Linux and the Android emulator, and a real force-stop and relaunch on the emulator.

### Phase 3: Browsing ✅ *(done 2026-11-19)*
- [x] Home (hero carousel, groups, catalog and genre rows, plain `booth` placeholders instead of shimmer per DESIGN.md, pull-to-refresh), genre detail and "See all" with infinite scroll, search, and details with episodes, cast and "More like this".
- [x] Home hero redesign (2026-11-19, DESIGN.md §8): peek carousel that loops forever and advances every 10 s, a centred bulb pager, the first 10 of the API's 85 banners (`heroBannerCap`), and fitted titles (`HeroTitle`: biggest size that shows the title whole, no broken words, balanced lines; real-font tests in `test/features/home/hero_title_test.dart`).
- [x] Paging: every long list is a `MediaSource` (`lib/data/paging/`) behind one `pagedMediaProvider`, which hides each endpoint's paging rules. The next page loads about 12 posters before the end; a failed page shows "Try again" and keeps what loaded. Two pages in a row with titles but none new end a list (2026-11-24): every endpoint answers an empty page past the end, but one repeating its last page would be paged forever. *Decision (2026-11-19): infinite scroll, not a "Load more" button or numbered pages.*
- [x] Image loading with the shared headers (`MediaImage`, decoded at display size, no fade). The parser picks card, HD and backdrop images (`posterUrl` / `hdPosterUrl` / `backdropUrl`).
- [x] Errors say what happened, and ask the status page once when the API fails (`ErrorView`). Riverpod's automatic provider retry is off (`noRetry`): `ApiClient` already retries once.
- [x] **Done when:** you can browse, search and open details for movies and series on Android and Linux. Checked by widget tests on fixtures, and `integration_test/screenshots_test.dart` against the live API on Linux and the Android emulator.

### Phase 4: Player
**The detailed plan is [`PLAYER.md`](PLAYER.md)**: targets, decisions, architecture, mpv setup, every feature, the controls, platform specifics, milestones M0–M9 and tests.
- *Progress (2026-11-19):* M0–M9 are done (the player is finished): measurements, engine and controller, the player screen, chip menus (subtitle size and sync, quality, speed, fit), and resume with watch history (drift). Checked on the owner's phone: the picture, quality and episode switches, smooth 4K, and resume after a force-stop.
  - **Android plays with ExoPlayer** (`video_player`, texture view), not media_kit: mpv stuttered on 4K there. Desktop keeps media_kit. Android has no styled (ASS) subtitles (PLAYER.md §2, decision 7).
- **M5 done (2026-11-19, checked on the owner's phone):** Next episode autoplay, the Up next card and countdown, "Still watching?", the Episodes panel.
- **M6 done (2026-11-19, checked on the owner's phone and Linux):** Skip intro and seek-bar previews.
- **M7 done (2026-11-19, checked on the owner's phone):** gestures, the controls lock, audio interruptions (immersive mode, wakelock and orientation were already in). M8 done on Linux (2026-11-19, checked by the owner): desktop keys, mouse, cursor hiding, full screen, saved volume, focus rings; Windows not run yet. **M9 done (2026-11-19):** 4K frame times and memory on the phone, the Arabic pass, every error state, the end-to-end test (PLAYER.md §15).
- *Linux, 2026-11-27:* the UI over a playing video runs at 60 fps (it was ~25): mpv's render waits for each frame's time only while the video is alone on screen. media_kit_video is now our copy in `third_party/` for that (PLAYER.md §14, `third_party/README.md`). The clock no longer shows 0:00 while a stream that starts later on opens (PLAYER.md §13). The memory work is in [`MEMORY.md`](MEMORY.md).
- *Decisions (2026-11-19):*
  - The drift `watch_history` table is built in this phase, so resume works now. Phase 5 adds the Library UI.
  - The seek bar always runs left → right, in Arabic too.
  - Next episode autoplays after a 10 s "Up next" countdown.
  - Extras in this phase: subtitle size and delay, seek-bar previews (moved up from Phase 7) and a controls lock on mobile.
  - No picture-in-picture for now.
- **Done when:** a movie and a full series play smoothly on Android, Linux and Windows, and every target in PLAYER.md §1 is met.

### Phase 5: Library *(built 2026-11-19, to check on the phone)*
- drift `favorites` table (`watch_history` already exists from Phase 4), the Library tab (Continue watching and Favorites), and a background metadata refresh with `getVideosByIds`.
- **Done when:** history and favorites survive a restart and resume works. Checked by the drift repository tests (including the upgrade of a schema 1 database), the Library widget tests and `integration_test/screenshots_test.dart` on Linux (phone, desktop, Arabic).
- **To check on the phone** (release APK installed over the current app, so its database is upgraded): existing Continue watching entries are still there; finishing an episode shows "Up next" on Home and in the Library; Favorite works from Details and the hero; a long press removes a card; everything survives a force-stop and relaunch.

### Phase 6: Downloads *(built 2026-11-19, to check on the phone)*
> **2026-11-21:** downloads fail on the phone (stuck "Paused", false "no connection", Retry can't continue, 11.5 GB of stray partial files). The fix is planned in [`DOWNLOADS.md`](DOWNLOADS.md) (milestones D0–D7), which replaces the phone check below.

- background_downloader for video plus subtitle, with the headers.
- Progress, speed, pause/resume/cancel, notifications on mobile.
- Storage location per platform:
  - Android: app-specific external directory
  - desktop: a folder the user picks, defaulting to `~/Videos/Cinemakom`
- Offline playback, delete, and grouping by series.
- **Done when:** a download finishes, plays offline with subtitles, and survives an app restart in the middle.
- *Built (2026-11-19):*
  - `lib/core/downloads/` (`Downloader`, with `BackgroundFileDownloader` the only file importing background_downloader), the drift `downloads` table (schema 3), and `DownloadsRepository` (queue, subtitles, events, fresh-URL resume, restart catch-up, delete). Downloads, Details buttons, and the desktop folder in Settings (file_selector).
  - Engine events, user actions and startup run one at a time, so a late progress event can't undo a finished or paused download.
  - The CDN needs `Range: bytes=0-` for pause and resume to work (API.md §3).
  - Partial files: not in Android's cache dir (it can be evicted), and on desktop next to the download folder, not in `/tmp`.
  - Checked: unit and widget tests, and `integration_test/downloads_test.dart` on Linux with the live CDN (download, pause, resume from the partial file, offline playback, delete).
- **To check on the phone:** a download with the screen off and the app in the background (notification with progress); pause and resume; force-stop mid-download, then reopen (it continues or shows Try again); airplane mode, then play the download with subtitles; Download season; delete; the Downloads page in Arabic. Windows is still to try.

### Phase 7: New features
- The rest of §4.2 (skip intro and seek-bar previews are built in Phase 4; cast and crew, actor pages and the library refresh are done): related titles, season picker, group "see all", genre × language filter, advanced filters, library refresh, FAQ.

### Phase 8: Polish and release
- Empty, error and offline states, accessibility (semantics, text scaling), and performance (image cache size, list `cacheExtent`).
  - *Done 2026-11-19:* Android asks for the display's fastest refresh rate (`MainActivity`). OnePlus/ColorOS had held the app at 60 Hz. On the owner's OnePlus (120 Hz) the frame-timing check (`integration_test/scroll_perf_test.dart`) measured: UI thread about 1.5 ms and raster about 4.2 ms on average against an 8.3 ms budget, with under 1% of frames late while scrolling and about 1.5% when opening a title. Those late frames are the page-transition snapshot, which is how Flutter is built. Re-run the check after big UI changes.
- *Done 2026-11-24:* a flight recorder for bugs that happen once (`lib/core/diagnostics`): uncaught errors, freezes (frames over 700 ms, the event loop blocked 1 s or more), the player's state changes, the remote's keys with the focus, screens, network failures and download steps, kept on the device in `logs/current.log` and `previous.log` (the last session). Settings → Help → Activity log shows it and hands it over: the share sheet on phones, Save a copy on computers, a QR code on the TV that opens it on a phone on the same Wi-Fi (`LogServer`, a random link, only while the panel is open). A part of a screen that fails to build shows the background in release builds (`BrokenPart`), not Flutter's grey box.
- Packaging: the plan is `docs/PACKAGING.md` (2026-11-24): files in the right folders first (XDG on Linux, Local/Roaming on Windows), then a per-user Inno Setup installer on Windows, and an AppImage with an install script as the only Linux package (Flatpak dropped 2026-11-24: Flathub won't take an AI-written app). Android is the APK. *P0 done on Linux (2026-11-24) and Windows (2026-11-26).*

---

## 6. Platform notes and risks

| Risk | Mitigation |
|---|---|
| `cached_network_image` → sqflite crashes on Linux and Windows | ✅ Handled: `main.dart` calls `sqfliteFfiInit(); databaseFactory = databaseFactoryFfi;` on desktop. It shares sqlite3 3.x with drift, so there's no version conflict |
| libmpv is missing on a user's Linux install | The AppImage bundles it (docs/PACKAGING.md §3). Show a clear error if the player fails to start |
| The API checks headers (Referer, Origin, User-Agent) | All requests go through the shared header map. If streams break on one platform, compare against the Kotlin app first |
| The API is undocumented and can change without warning | Parsers stay tolerant. Fixture tests catch changes. Re-run the capture script to compare |
| ~~Unknown stream formats (mp4 vs HLS)~~ | ✅ Resolved: every stream is progressive MP4 (H.264 + one AAC track), with no HLS or DASH (API.md §3) |
| `popularFilms`, `latestVideosItems`, `collectionVideos` return nothing | Leave them out of the UI until they return data |
| Arabic text and RTL in subtitles and mixed-language titles | UI: the bundled IBM Plex Sans Arabic and Reem Kufi act as font fallbacks, so mixed-script titles render correctly (DESIGN.md §2). Use `Directionality` per text when a title mixes scripts. Subtitles: the proposal is to use IBM Plex Sans Arabic as the libass fallback font. libass reads fonts from disk, not from Flutter assets, so copy it out at startup |
| Desktop input (no touch) | Controls must work with keyboard and mouse. Gestures are mobile only. Show hover states and scrollbars on desktop |
| Data from the old Android app (Room) | **Not migrated.** This is a new app with a new database. Document it for existing users |

---

## 7. Testing

- **Unit:** every parser against real fixtures, plus repositories with a mocked Dio. This matters most, because the JSON is where things break.
- **Widget:** the cards, the home rows (loading, error and data states), the settings toggles, RTL layout.
- **Integration:** use `integration_test` to run launch → search → open details → play for 5 seconds. Run it on an Android emulator and a Linux desktop.
- **Manual check before each release:** go through every §4 checkbox on Android (phone and TV), Linux and Windows.

---

## 8. Open decisions
1. ~~Application ID and org~~ ✅ `io.github.sharon_xa.cinemakom`.
2. ~~Riverpod codegen~~ ✅ No codegen: plain `Provider`s, no `riverpod_generator` (and no freezed, see §2).
3. ~~Details layout~~ ✅ A full page on every platform, two columns on desktop (§4.1 Details). *Changed 2026-11-19 from "a sheet on mobile" during the screen design.*
4. ~~Download folder on desktop~~ ✅ The user picks it, defaulting to `~/Videos/Cinemakom` (Phase 6). It can be changed in Settings.
5. Add Shabakaty sign-in later (unlocks server-side history, likes, comments)? Out of scope for v1.
