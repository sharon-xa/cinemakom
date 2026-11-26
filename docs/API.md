# Cinemana API Reference

The reverse-engineered API that Cinemakom is built on. **This file is the source of truth.** The old Kotlin app (`../cinematy`) got several things wrong (sort codes, genre IDs, search encoding, subtitles), so don't trust it over this file.

**How this was verified (second deep dive, 2026-11-19):**
- **The official website** (`https://cinemana.shabakaty.com/home`) in Chrome. Every guest page was visited and its requests recorded: home, new releases, popular, movies, series, anime, a genre, search (suggestions and the results page), a movie, a series, an episode switch, the season row, staff, a group's "see all", a collection, FAQ, settings as a guest and the Arabic switch. In the player: quality switch, subtitles menu and skip intro.
- **The website's JavaScript** (`main.d454b5f16dee02a7a9d8.js`, 3.3 MB, no lazy chunks). It was read as text: the full endpoint map, every call site's parameters, the sort list, the filter names and the player logic.
- **The official Android app** (Shabakaty Cinemana 5.3.3, `com.shabakaty.cinemana`, from APKPure). It was unzipped and its dex string tables read; it was never run (§6).
- **Live probes** (at most 6 requests at a time) of every parameter: accepted values, missing/empty/invalid/out of range/past the end, paging, limits, errors, headers and caching.
- **A field-level survey:**
  - 497 `allVideoInfo` records (200 movies, 100 series, 197 episodes);
  - 1,037 stream files from 200 titles;
  - 200 subtitle sets (26 files downloaded);
  - 150 seek-preview sets;
  - 100 series with 8,721 episodes;
  - 60 staff pages and 60 recommendation answers;
  - ffprobe on 480p, 1080p and 2160p files.
- **Captured responses** in `test/fixtures/`. Re-capture them with `fvm dart run tool/capture_fixtures.dart`.
- **Two repeatable live checks** that use the app's own code:
  - `fvm dart run tool/api_contract_check.dart` verifies every behaviour the code relies on. **Run it before each release and whenever data looks wrong.**
  - `fvm flutter test integration_test/api_debug_test.dart -d linux` exercises every repository end to end.

Status legend: ✅ used · ⚙️ works but unused · ❌ dead or broken · 🔒 needs a login (out of scope) · 🚫 excluded on purpose (zero censorship, no ratings, no telemetry).

---

## 1. Hosts

| Host | What | Status |
|---|---|---|
| `cinemana.shabakaty.com/api/android/` | The main API: JSON over GET, plus one form POST | ✅ |
| `recommend.shabakaty.com` | "More like this", JSON POST, no login | ✅ |
| `cnth2.shabakaty.com` | Posters, covers, staff photos, subtitles, seek-preview sprites. Posters aren't signed; subtitles are | ✅ |
| `cdn.shabakaty.com` → `cndw1…6.shabakaty.com` | Video files. `cdn` answers **302** to a node; follow redirects | ✅ |
| `6b1m6vnfz2jk.statuspage.io/api/v2/components.json` (`shabakaty.statuspage.io`) | Public Atlassian status page with a "Cinemana" group, used by the Android app | ✅ `StatusRepository.cinemanaHealth()`, only after API calls fail |
| `thumbnail.shabakaty.com/api/series/seasonposters` | Season posters | ❌ 500, also on the website |
| `rating.shabakaty.com` | User ratings | 🚫 ratings; also needs the bundle's app ID |
| `cinemana.shabakaty.com/api/info/{ShabakatyInfo,userInfo}/`, `…/whatismyip`, `share./tv.shabakaty.com/whatismyip`, `shabakaty.com/clip/`, `hacheckphp.php` | Telemetry and ISP/IP checks (POSTs device info) | 🚫 never call |
| `se.shabakaty.com` (Sentry), `aj2376.online` (ads), `api.onesignal.com`, `api.ipify.org`, Yandex, New Relic | Error reporting, ads, push, analytics | 🚫 |
| `contwatch.shabakaty.com`, `account.shabakaty.com` | Watch progress, accounts | 🔒 |
| `updates.shabakaty.com/api/apps/7` | The Android app's own update feed | not relevant |

## 2. Conventions

### Headers
The website sends `User-Agent`, `Referer: https://cinemana.shabakaty.com/` and `Origin: https://cinemana.shabakaty.com`. **None of them is required** by any endpoint, including the two POSTs, the image host and the video CDN. This was tested with no headers at all, and with curl and Dart user agents. We still send them on every request through the one shared map, `ApiClient.defaultHeaders`, in case the servers start checking.

### Parental level: always `0`
Every `level` parameter is a parental level. **`0` is the unrestricted level** and returns the full catalog: 85 banners, versus 33 at level 2 and 13 at level 3. Levels 1, 4, 5, 6, 99, `-1` and `abc` behave like 0. Cinemakom always sends `0`, with no setting to change it (the zero-censorship rule in AGENTS.md).

### Language
`lang` accepts `ar` or `en`. For `videoGroups` anything else means English. For `mainCategories` / `subCategories`, an unknown value means **Arabic** and a missing one English. `lang` only changes text the server localizes itself (group titles, category names, the staff role). Media items always carry both `en_title` and `ar_title`.

### Kind
`videoKind` / `kind`: `1` = movies, `2` = series. Unknown codes (`0`, `3`, `abc`) mean `1`. `AdvancedSearch` uses `type=movies|series`, and **without a valid `type` it returns movies only**.

### Sort codes
These are `sortParam` on the catalog and `orderby` on `videosByCategory…`. They are the website's full list (`sortingOptions`), checked against the order of live results:

| Code | Meaning | Catalog | `videosByCategory…` | `SortOrder` |
|---|---|---|---|---|
| `desc` | Recently **uploaded** first (the default) | ✅ | ✅ | `recentlyAdded` |
| `asc` | Oldest uploads first | ✅ | ✅ | `oldestAdded` |
| `r_desc` | Newest **release date** (`mDate`) first. **Not "top rated"** | ✅ | ✅ | `newestRelease` |
| `r_asc` | Oldest release date first. Junk `mDate`s (year 201) come first | ✅ | ✅ | `oldestRelease` |
| `title_asc` / `title_desc` | By raw `en_title`, database collation (leading spaces and punctuation first) | ❌ ignored (gives `desc`) | ✅ | `titleAscending` / `titleDescending` (`worksOnCatalog: false`) |
| `views_desc` | Most watched first | ✅ | ✅ | `mostViewed` |
| `views_asc` | Least watched first | works | works | not used (no use case) |
| `rating_asc` / `rating_desc` | Parental (age) rating | works | works | 🚫 no ratings |
| `stars_asc` / `stars_desc` | IMDb score | works | works | 🚫 no ratings |

**Never send any other code.** An unknown code (or an empty one) gives `desc` on the catalog, but on `videosByCategory…` it gives a **stars order**. `AdvancedSearch` ignores `sort`, and so does the website, even though its UI sends it. `CatalogRepository.catalog` throws `ArgumentError` for title sorts.

### Paging

| Endpoint | Scheme | Page size | End of list |
|---|---|---|---|
| `video/V/2/…/pageNumber/{n}` (catalog) | 0-based page | `itemsPerPage`, **capped at 99**; `0` gives 10 | empty page |
| `video/V/2/itemsPerPage/A/video_title_search/{q}/itemsPerPage/B/…` | 0-based page | **`B` counts, `A` is ignored**; cap 98–99 | empty page. **Pages can be one item short mid-list** (50 asked, 49 given) |
| `latestMovies` / `latestSeries` `…/page/{n}/` | 0-based page | `itemsPerPage`, **no cap** (1000 works); `0`/`abc` gives 12/`[]` | empty page |
| `featuredMovies …/page/{n}` | 0-based page | `itemsPerPage`, no cap; 480+ items in total | empty page |
| `videoListPagination …/page/{n}` | 0-based page | `itemsPerPage` (12 on the website; 24 and 100 work) | short page, then empty pages |
| `videosByCategory`, `videosByCategoryAndLanguage` | **item offset** (`offset=30` skips 30); the response's `offset` is the next one | 30, fixed | short page. Past the end, `offset` keeps growing, so never stop on its absence |
| `AdvancedSearch` | 0-based `page` | 12, fixed (`itemsPerPage` ignored) | **empty page**: mid-list pages of 11 occur |
| `newlyVideosItems/…/offset/{n}/` | **`n` is a count**, capped at 12 | ≤ 12 | n/a |
| `latestVideosItems/…/offset/{n}/` | `n` is a count, **no cap** (2000 works) | n | n/a |
| `staff`, `videoSeason`, `relatedVideos`, recommendations | not paged | all at once | n/a |

A negative page or offset counts as 0. Past the end, every list endpoint answers `200` with an empty list.

### Responses
- **IDs** are under `nb`, as strings. `"0"` means "none" (e.g. `rootSeries: "0"`). Staff IDs and video IDs share one number space but are different things.
- **Numbers usually arrive as strings** (`"7.5"`), but not always (`videoCommentsNumber` is a number). The string `"null"` also appears, and booleans appear as JSON booleans (`hasIntroSkipping`) and as strings (`castable: "true"`).
- **Ratings and counters aren't used.** The app has no ratings (AGENTS.md), so `stars`, `rate`, `filmRating`, `seriesRating`, `ratingImg`, `Likes`, `DisLikes`, `videoLikesNumber` and `videoDisLikesNumber` are never parsed. **`videoViewsNumber` is always `0`**, so view counts can't be shown either.
- **Titles are often untranslated:** 56% of records have identical `en_title` and `ar_title`, some `en_title`s are in Arabic, and 3% have stray leading or trailing spaces. Show `ar_title` in Arabic and `en_title` in English, and trim.
- **`custom_en_title` / `custom_ar_title`** on group items are the **group's** name, not the item's. Ignore them.
- **Content types are unreliable** (`text/html` for empty bodies, `binary/octet-stream` for some videos), so the client reads bodies as text and decodes the JSON itself.

### Caching
- An nginx and HAProxy cache sits in front of the API (`x-cache-status-nginx: HIT|MISS|STALE|BYPASS`).
- `Cache-Control` is `max-age=600` for lists (banner, groups, catalog, latest, categories by genre) and `max-age=1800` for details, playback, categories and search. Both add `stale-if-error=3600`. `featuredMovies` and title search send none.
- **The cache serves stale `transcoddedFiles` answers whose signed URLs have already expired** (see Streams).
- Any extra query parameter bypasses the cache: `?_=<unique>` (`ApiEndpoints.streams(cacheBuster:)`).

### Speed and concurrency
- Median responses take 70–150 ms. `categoryLangFreqVideo` takes about 400 ms, and `featuredMovies` once took 9 s when uncached.
- 40 parallel requests all succeeded (no rate limiting), but the server slows to a crawl with 20 at once.
- `ApiClient` runs at most 6 requests at a time and retries a failed GET once, on network errors, timeouts and 5xx only.

### Errors

| Situation | Response |
|---|---|
| Unknown endpoint, or GET on a POST endpoint | `404 {"status": false, "error": "Unknown method."}` |
| `allVideoInfo`: unknown ID | `400 []` |
| `allVideoInfo`: `0` / `abc` | `400`, empty body |
| `allVideoInfo` for some deleted or broken titles (e.g. `1184051`) | **`200`, empty `text/html` body**, while its episodes and streams still exist |
| `transcoddedFiles`: unknown / negative ID | `200`, empty body |
| `transcoddedFiles`: `0` / `abc` | `400`, empty body |
| `translationFiles`: unknown ID | `200`, with `defaultImages/loading.gif` placeholders and no `translations` |
| `videoSeason`: unknown / invalid ID | `400`, empty body |
| `videoSeason`: a movie ID | `200 []` |
| `videoSeasonNumber`: unknown / movie ID | `400`, empty body |
| `video_thumbnails`: unknown ID | `200 {"videoThumbnails": [], "status": 204}` |
| `video_thumbnails`: `0` / negative | `400 {"message": "bad Request"}` |
| `staff`: unknown ID | `200 []` |
| `staff`: `0` / `abc` | `500`, empty body |
| `relatedVideos`: unknown ID | `200 []` |
| `videoListPagination`: unknown group | `200 []` |
| `videosByCategoryAndLanguage` without `language_id` | `400 "bad request"` |
| `AdvancedSearch?page=abc` | `200`, empty body |
| Title search with a raw `=` or `+` in the path | `400` |
| Title search with an invalid base64 segment | `400` HTML page ("Under maintenence") |
| `getVideosByIds` with more than 40 IDs | `400 "max array 40 item"` |
| `getVideosByIds` without brackets, or as JSON | `200`, empty body |
| Recommendation: non-numeric `MovieId` | `400` |
| Recommendation: form body | `415` |
| Recommendation: GET | `200`, empty `temp` answer |

## 3. Data model

### Media items
Lists and details share one record shape. The useful fields:

| Field | Meaning |
|---|---|
| `nb` | ID |
| `en_title`, `ar_title`, `other_title` | Titles. `other_title` is the original-language title (37% non-empty) |
| `en_content`, `ar_content` | Synopsis (1% empty) |
| `kind` | `1` movie, `2` series |
| `year`, `mDate` | Release year, release date `YYYY-MM-DD` (always set, sometimes junk: `0201-05-31`, `2028-06-28`) |
| `duration` | Seconds, as a string with or without decimals (`"6010.03"`, 909–15,790 s seen) |
| `rootSeries`, `season`, `episodeNummer` | Series structure (two m's). Movies have `season` and `episodeNummer` `"0"` |
| `episode_flag` | Episode label, see Series |
| `imgObjUrl`, `imgMediumThumbObjUrl`, `imgThumbObjUrl` | Images, see Images |
| `categories` | `[{en_title, ar_title}]` |
| `imdbUrlRef` | IMDb link (in several URL forms), **or a MyAnimeList link for 8% (anime)**, or `""` (12%). `MediaDetails.imdbUrlIsImdb` |
| `trailer` | YouTube watch URL (71%), sometimes with HTML-escaped junk (`&ab;_channel=`), once an IMDb video. `MediaDetails.trailerYoutubeId` |
| `itemDate`, `videoUploadDate`, `publishDate`, `updateDateTime` | Upload dates (`YYYY-MM-DD hh:mm:ss`) and a Unix timestamp |
| `hasIntroSkipping`, `introSkipping` | Intro ranges, see Intro skipping |
| `videoLanguages` | **Always an object** `{en_title, ar_title}`: the audio language (the list form was never seen) |
| `arTranslationFile(Path)`, `enTranslationFile(Path)`, `spTranslationFile`, `translations` | Subtitles, see Subtitles |

**Fields that are meaningless or not modelled:**
- `isSpecial` (15% `"1"`; it correlates with nothing, and the website doesn't use it)
- `audioStreamNumber` (`0`–`14`, but every file has **one** audio track, see Streams)
- `orderNmmer` (always `"1"`)
- `useParentImg` (always `0`)
- `isDeleted` (`"2"` on a few titles that are still served)
- `collectionID` (always `"0"`)
- `castable` (always `"true"`)
- `fileFile`, `fileSizeServer`, `objectUrlExpiration`, `language_lighttigerNb`, `CACHE_SHORT`, `showComments` (always false)
- `parent_skipping` and `skippingDurations` (🚫 parental scene skips, also embedded in `allVideoInfo`)

### Series and episodes
A series has **no separate record**. It is represented by its **first episode (S1E1)**, which has `rootSeries: "0"`. Every other episode has `rootSeries` set to S1E1's `nb`, so **series ID = `rootSeries`, or the item's own `nb` when `rootSeries` is `"0"`** (`MediaItem.seriesId`). `latestSeries`, the series catalog and staff pages list S1E1 items.
- `videoSeason` returns every episode **unsorted** (only 59% of series come sorted; Friends has 234 episodes starting at S9E1). Sort by season, then episode. Numbering has gaps in 7% of series, and some seasons don't start at 1.
- **Episodes have no titles of their own.** Most repeat the series name. Some repeat a *season* name ("Attack on Titan Final Season", "Tokyo Ghoul:re"), or spelling variants of the series name. Their synopsis repeats too. **Cinemakom never uses episode titles.** Images are per season.
- **`episode_flag` sets the label**, decoded as the website does (`EpisodeNumbering.fromFlag`):
  - `0000` → N
  - `1000` → N, final episode (23 of 100 series have one)
  - `0001` → N − 1
  - `1001` → N − 1, final
  - `0010` → N & N + 1, a double episode (33 occurrences)
  - `0020` / `0100` → N & N + 1 & N + 2
  - Anything else → N.
- **`videoSeasonNumber` can return `[]`** for a series that has episodes. `MediaRepository.seasons` then takes the seasons from the episodes.

### Images
- **Posters** are portrait, from `cnth2…/vascin-poster-images/{uuid}_poster.{jpg|png|webp|jpeg|jfif}`:
  - `imgThumbObjUrl`: 100 px wide (`…_poster_thumb.*`). Use for tiny placeholders.
  - `imgMediumThumbObjUrl`: **293 px wide**, height varies (366–443; usually 439, so not always 2:3). Use for cards and grids.
  - `imgObjUrl`: the original upload, **anywhere from 253×383 (20 KB) to 2000×3000 (2.5 MB, sometimes PNG)**. Details and hero only, decoded at display size (`cacheWidth`). Never in lists, except the Android TV UI, which swaps it in for cards on screen (`docs/TV.md` §9.1).
- **Banner covers:** `banner` items have a **wide** `imgObjUrl` (`vascin-cover-images/…_cover.jpg`, 1350×500, 3544×1313, 3881×1437 or 4050×1500, about 2.7:1, 170–420 KB). It is the only landscape artwork the API offers; there are no other backdrops. Their `imgMediumThumbObjUrl` is a **relative path** to the 293-wide portrait poster: resolve it against `https://cnth2.shabakaty.com/` (`resolveImageUrl`). `img`, `imgThumb` and `imgMediumThumb` are bare file names: ignore them.
- **Staff photos:** `staff_img` / `staff_img_medium_thumb` are 293 wide, `staff_img_thumb` 100 wide. 24% are `null`, and 17% are `defaultImages/not_available.jpg`, which answers 503.
- **Placeholders** must be rejected wherever an image is read (`isPlaceholderImage`). They are:
  - `https://cinemana.shabakaty.com/loadingImages/loading.gif` (47% of staff pages, almost every category)
  - `defaultImages/loading.gif`
  - `defaultImages/not_available.jpg`

### Streams (`transcoddedFiles`)
`[{name, resolution, container, transcoddedFileName, videoUrl}]`.
- **Formats:** every stream is **progressive MP4** (`container: "mp4"`); there is no HLS or DASH. Almost all streams are **8-bit H.264 High (`avc1`, `yuv420p`)**, with a small number of recent 2026 4K titles in **8-bit HEVC Main (`hvc1`, `yuv420p`)**, at 23.976 / 24 / 25 fps, plus **one** AAC-LC 2.0 stereo track (48 kHz), even where `audioStreamNumber` or `realFileName` says more.
- **Qualities:** `240p`, `360p`, `480p` (named `m480`), `720p`, `1080p`, and **`2160p`** (`mp4-4k`) on 22% of titles. 3% lack 1080p.
- **Frame size:** the "p" is a size class; wide films are shorter (a "2160p" file can be 3840×1820).
- **File sizes:** 4K is about **22 Mbit/s, 10 GB per hour** (18–20 Mbit/s for the rare HEVC 4K files); 1080p is 1.7–3.9 Mbit/s. Measured throughput from the development machine was about 26 Mbit/s.
- **File sizes and ranges (2026-11-19, for downloads):** the API never sends a file size. A stream URL answers `302` to a `cndwN.shabakaty.com` host, which serves the file.
  - `HEAD` gets **403** (the URL is signed for GET). To learn the size, ask for one byte: `GET` with `Range: bytes=0-0` answers `206` with `Content-Range: bytes 0-0/<total>` (`ApiClient.contentLength`). Only the headers are read, then the request is cancelled: a server that ignored the range would send the whole video, which `ResponseType.bytes` held in memory (2026-11-24; dio reads a stream body itself, so only its `CancelToken` closes the connection). Example: Friends S1E1 is 49 MB at 240p and 710 MB at 1080p.
  - Ranges work (`206`, a strong `ETag`), but a plain `200` sends **no `Accept-Ranges`**, so background_downloader would think a download can't be paused or resumed. Downloads therefore ask for `Range: bytes=0-` from the start, which gets a `206` for the whole file; resuming adds its offset to that range. Checked live: pause at 11%, resume with a fresh signed URL, and the file finished at its exact size.
  - A signed URL lives about five days, so paused and failed downloads are always resumed with a fresh one (`streams(fresh: true)`).
- **Fast start:** 1080p and lower files are **not fast-start** (`moov` comes after a GB-sized `mdat`), so a player must make a ranged read of the tail first. The 4K files are fast-start.
- **CDN:** `cdn.shabakaty.com` answers 302 to a `cndwN` node, which answers byte ranges with `206`. No headers are required. Some nodes send `binary/octet-stream`.
- **Series:** request an **episode** ID.
- **Signed URLs** carry `AWSAccessKeyId`, `Expires` and `Signature`, plus `response-content-disposition` (videos) or `response-cache-control` (subtitles).
  - The server **reuses each file's signature until it expires, at most 7 days**, so a URL can arrive with anywhere from 0 to 7 days left.
  - The API cache **can even serve URLs that expired hours ago**. Whether those then fail depends on the CDN node (403 `AccessDenied` on some, 206 on others).
  - `MediaRepository.streams` therefore refetches past the cache when any URL expires within 6 hours.
  - Players and downloads must call `streams()` again on a 403.
  - Never store stream URLs.
- **Subtitle URLs** last about 30 days.

### HDR, Dolby Vision, Dolby Atmos and codecs (2026-11-26 survey)
Verified against **833 unique titles** (recent 2025–2026 uploads, featured, most-viewed, banners, and major 4K/HDR/Atmos blockbusters and series), probing the binary MP4 `moov` boxes of **210 live streams** (**181 × `2160p`** and **29 × `1080p`**, plus `720p`/`1080p` tier cross-checks) and cross-verifying 13 streams directly through FFmpeg (`libmpv-2.dll`).

**Summary:** Cinemana has **no real 10-bit HDR10, Dolby Vision, or Dolby Atmos/surround support** — neither in the API metadata nor in its transcoded streams.

| Technology | Source `realFileName` | Delivered streams (210 probed) | Notes |
|---|---|---|---|
| **HDR10 (10-bit PQ + `mdcv`/`clli`)** | 0 explicit `HDR`/`HDR10` tags seen; uploaders mostly ingest 4K SDR WEB-DLs | **0 / 210** (0%) | Every stream is transcoded to **8-bit `yuv420p`** (`0` 10-bit streams, even from `x265.10bit` sources such as `3117962`) |
| **8-bit PQ / HLG passthrough** | Rare (`HLG` seen once: `3159152`; unmarked PQ source: `3137246`) | **2 / 181** `2160p` (~1.1%), **carried to all tiers** (`720p`, `1080p`, `2160p`) | Unintentional tag passthrough: transcoded to 8-bit `avc1` (`yuv420p`) with `colr` (`BT.2020` + `PQ` or `HLG` + `BT.2020nc`), **no** `mdcv`/`clli` static metadata (`max-cll=0`), and no SDR tone-mapping applied server-side |
| **Dolby Vision** | 0 seen | **0 / 210** (0%) | Zero `dvcC`/`dvvC`/`dvwC` boxes, zero `dvh1`/`dvhe` tracks, zero RPU metadata. Even when a source container carried a `dby1` brand in `ftyp` (`3117962`), the output is plain 8-bit `avc1` BT.709 SDR |
| **Dolby Atmos / Surround (5.1/7.1)** | Common (`143+` `DDP5.1`/`DD+`/`EAC3`, `52+` `Atmos`, `11` `DTS`/`TrueHD`) | **0 / 210** (0%) | **100%** downmixed and re-encoded to **1 track of `mp4a` (AAC-LC) 2.0 stereo at 48 kHz** (~180–300 kbit/s on 4K). Zero `ec-3`/`ac-3`/Atmos JOC (`dec3`) or multi-channel tracks |
| **Video codecs** | Mostly `H.265`/`HEVC` on 4K sources | `2160p`: **178 `avc1`** (98.3%) + **3 `hvc1`** (1.7%)<br>`1080p`: **29 `avc1`** (100%) | The 3 `hvc1` streams (`3150062` *Sacrifice*, `3150056` *Tenzing*, `3148886` *Love of Your Life*, all 2026) are **8-bit HEVC Main (`yuv420p`, BT.709 SDR, 18–20 Mbit/s, `Lavf59.27.100`, fast-start)**; their `1080p`/`720p` tiers remain `avc1`. Zero AV1 or VP9 |
| **API metadata** | `realFileName` only (unreliable for output) | None | Neither `allVideoInfo` nor `transcoddedFiles` exposes HDR, codec, bit depth, or channel fields. `transcoddedFiles` always has only `{name, resolution, container, transcoddedFileName, videoUrl}` |

**Transcoder behavior and client implications:**
- **Transcoder fingerprint:** `1080p` and lower are always written by `Lavf59.27.100` (FFmpeg 5.1), `avc1` H.264 High 8-bit, tail-`moov` (`fast_start: false`, 29/29). `2160p` files are always fast-start (`moov` at head, 181/181) at ~22.1 Mbit/s median (15.5–22.2 Mbit/s); the 178 `avc1` 4K files omit the `©too` tag while the 3 `hvc1` 4K files carry `Lavf59.27.100`.
- **Color tags (`colr`):** 175/181 `2160p` and 25/29 `1080p` streams explicitly signal `BT.709 / BT.709 / BT.709` (`nclx`); 4 `2160p` and 4 `1080p` omit `colr` and decode as BT.709 SDR in FFmpeg. Only the 2 titles above (`3137246` PQ, `3159152` HLG) carry `BT.2020` + `PQ`/`HLG` tags — and they do so across **every** resolution (`720p`, `1080p`, `2160p`), not only 4K.
- **Implications for HDR support in Cinemakom:**
  - Dedicated 10-bit HDR10 / Dolby Vision passthrough or UI "HDR / DV / Atmos" badges have **no real server support** today (never infer HDR/DV/Atmos from `realFileName`, which describes the raw upload before transcoding).
  - For the rare ~1% of streams with accidental 8-bit `BT.2020/PQ` or `BT.2020/HLG` tags, players should preserve standard color-management / SDR tone-mapping (which `libmpv` does by default on desktop and ExoPlayer does on modern Android) rather than stripping or ignoring `colr` metadata, otherwise those titles wash out.
  - Because `hvc1` (HEVC) now appears on a small share of 2026 4K titles, desktop and Android players must continue supporting both H.264 and HEVC at 2160p.

### Subtitles (`translationFiles`, and `translations` in `allVideoInfo`)
`{arTranslationFile, arTranslationFilePath, enTranslationFile, enTranslationFilePath, spTranslationFile, translations?: [{id, name, type, extention, file}]}`. The key is spelled `extention`.
- **Each plain language comes twice**, as `srt` and `vtt`. In the survey, 75% of titles had Arabic, 48% English, and 24% none (no `translations` key; the paths hold `defaultImages/loading.gif`). No other languages exist.
- **Styled "special" subtitles:** 11% of titles (almost all Japanese anime) add an **ASS** file.
  - It appears as `{type: "sp", name: "special", extention: "ass"}` in `allVideoInfo`, but as **`{type: "arabic", name: "arabic", extention: "ass"}` in `translationFiles`**.
  - It is styled **Arabic**: UTF-8 **with a BOM**, CRLF line endings, `PlayRes` 640×360 or 1280×720.
  - It names fonts such as "Adobe Arabic", which the player won't have.
  - Some are huge (2.5 MB of karaoke effects).
  - `parseSubtitles` makes it an `ar` track with `SubtitleFormat.ass` (`isStyled`), and `oneTrackPerLanguage` offers it separately from the plain Arabic track.
  - The website plays only the `vtt` tracks from `allVideoInfo`, with Arabic as the default, and renders the ASS track with SubtitlesOctopus.
- **SRT** files are UTF-8 **without** a BOM and mix `\n` and `\r\n` within one file. **VTT** files use `\n` only. The `Content-Type` is `text/plain` or `application/octet-stream`.
- Only accept real `http(s)` subtitle files. One title had a `.txt` Arabic path.

### Intro skipping
`allVideoInfo.introSkipping` is `[{start, end, control_level}]` in seconds, as strings. It is present when `hasIntroSkipping` is true (57% of titles) and `null` otherwise.
- These are **real intro ranges**: 1 range for 78% of those titles, 2 for 20% (a cold open, then the intro), 3 for 2%. For example, `0→11.9 s` and `230→291 s`.
- `control_level` is always `"3"` and means nothing to us.
- Every range seen has end > start.
- The website shows "Skip intro" while the playhead is inside a range and jumps to its `end`. Use it for the same button (`MediaDetails.introRanges`).

### Seek-bar previews (`video_thumbnails`)
`{videoThumbnails: [{id, video_item_id, image_name, url, sprite_url, order, height, status, ModifiedOn, updated_date_time}], status}`. `status` is `204` with an empty list when a title has none (49% of titles).
- **Sheet layout:** each sheet is a PNG **1200 px wide**: 10 columns × up to 10 rows of **120×68** frames, **one frame every 10 s**, row-major. The website hard-codes the same geometry (`interval 10, width 120, height 68`).
- **`height` is the sheet's real pixel height**: 68 × rows, with 680 for a full sheet. The **last sheet is usually shorter** (e.g. 408 = 6 rows). `SeekPreview` keeps each sheet's row count and returns no frame past it.
- **Broken sheets** have `height: "0"`, and their file is an XML error. They keep their place with 0 rows.
- Some titles have **fewer sheets than their duration needs**, so previews stop early.
- Prefer `sprite_url`, which is absolute. Otherwise prefix `url` with `https://cnth2.shabakaty.com/`.

### Staff
- `allVideoInfo` lists people in `actorsInfo`, `directorsInfo` and `writersInfo` as `[{nb, name, role, staff_img, staff_img_thumb, staff_img_medium_thumb}]`. `role` is `"2"` for actors, `"1"` for directors and `"3"` for writers. 39% of titles list no director and 31% no writer.
- The staff page is `{title, role, imgObjUrl, imgThumbObjUrl, imgMediumThumbObjUrl, items}`.
  - `role` is one localized string ("Actor" / "الممثل", "Director", "Writers"), and it is **unreliable**: one person can have several staff IDs (Christopher Nolan has three), each with its own role.
  - `items` are S1E1 and movie records, newest year first, all at once (up to about 40).

## 4. Endpoints: coverage matrix

**Source:** W = the website bundle's endpoint map · C = seen in Chrome network traces · A = the Android app's strings. Relative paths are under `https://cinemana.shabakaty.com/api/android/`. All are GET unless marked.

### Home and catalog

| Endpoint | Source | Status | Verified parameters and behaviour | Response |
|---|---|---|---|---|
| `banner/level/0` | W C A | ✅ `banners()` | 85 items; level 2 gives 33, level 3 gives 13. All distinct: the site's promotion history, a few picked titles first, then recent promotions newest first. The hero shows the first 10 (`heroBannerCap`) | Media records, plus `link`: `https://cinemana.shabakaty.{com,cc}/video/{lang}/{id}?showInfo=…` or `?lastEpisodeVideoID={episode}`, the episode to open (`MediaItem.linkedEpisodeId`) |
| `videoGroups/lang/{lang}/level/0` | W C A | ✅ `videoGroups()` | Unknown `lang` means English | `{groups: [{groupsID, title, content: [12 media], hasPagination: 1, analytics: {eventID, eventInt}}]}`. **The ID key is `groupsID`.** `analytics` is telemetry: ignore it |
| `videoListPagination/groupID/{id}/level/0/itemsPerPage/{n}/page/{p}` | W C A | ✅ `videoGroupPage()` | `n` up to 100; page 0 equals the group's `content`. A query form also works | Media list |
| `featuredMovies/level/0/itemsPerPage/{n}/page/{p}` | W C A | ✅ `featured()` | Movies only, `n` uncapped. The website only loads page 0 | Media list |
| `latestMovies/level/0/itemsPerPage/{n}/page/{p}/` | W C | ✅ `latestMovies()` | `n` uncapped (1000 works); the trailing slash is optional | Movies |
| `latestSeries/level/0/itemsPerPage/{n}/page/{p}/` | W C | ✅ `latestSeries()` | Same | S1E1 items |
| `newlyVideosItems/level/0/offset/12/` | W C A | ✅ `newlyAdded()` | The website's home "New releases" row. Count capped at 12, movies only | Media list |
| `latestVideosItems/level/0/offset/{n}/` | W | ⚙️ | `n` items, uncapped, movies only. The same list as `newlyVideosItems`; the website never calls it | Media list |
| `video/V/2/itemsPerPage/{n}/level/0/videoKind/{k}/sortParam/{s}/pageNumber/{p}` | W C A | ✅ `catalog()` | **The main catalog**, all genres (the website's genre "-1"). Sorts: see §2. The query form `video/V/2?itemsPerPage=…&videoKind=…` (what the APK uses) is equivalent; extra filters (`category_id`, `videoTitle`, `q`) are ignored | Media list |
| `popularFilms/kind/{D,W,M,Y}/level/0/page/{p}` | W C | ❌ | Always `[]`; the website's Popular page says "There is no content" | `[]` |

### Categories and languages

| Endpoint | Source | Status | Verified parameters and behaviour | Response |
|---|---|---|---|---|
| `mainCategories?lang=` | W C | ✅ `genres()` | 15 main genres, sorted by title in the requested language. **84** Action, **56** Adventure, **57** Animation, **59** Comedy, **60** Crime, **61** Documentary, **62** Drama, **67** Fantasy, **70** Horror, **76** Mystery, **77** Romance, **78** Sci-Fi, **79** Sport, **80** Thriller, **89** Western (`fallbackGenres`) | `[{nb, title}]` |
| `subCategories?lang=` | W C | ✅ `genres()` | 34 secondary genres (Biography, Family, Supernatural, Program…) | `[{nb, title}]` |
| `category` | W A | ✅ `allCategories()` | 50 = main + sub + `0` ("uncategorized"). No parent/child structure. Images are all the `loading.gif` placeholder | `[{nb, en_title, ar_title, description, porder, sort, img…, updateDateTime}]` |
| `categoryLangFreqVideo` | W C | ✅ `categoryLanguages()` | 50 categories × 56 audio languages = 823 pairs. `langFreq` (movies) and `langFreqSeries` are accurate counts, but often `""` (= 0) | Categories + `langArray: [{catNb, langNb, lang_en_title, lang_ar_title, langFreq, langFreqSeries}]` |
| `videosByCategory?categoryID=&orderby=&videoKind=&offset=&level=0` | W C | ✅ `videosByCategory()` | 30 per page, item offset. All sorts in §2 work, including title sorts. `categoryID=-1` gives `[]` (the website uses the catalog instead). `0` (uncategorized) works. With no parameters it returns a default list | `{info: [media], offset: next}` |
| `videosByCategoryAndLanguage?category_id=&language_id=&orderby=&videoKind=&offset=&level=0` | W C | ✅ `videosByCategoryAndLanguage()` | Same shape and sorts. `language_id` is a `langNb` (7 English, 9 Arabic, 22 Japanese, 25 Turkish…), and missing it gives 400. **Anime** = `category_id=57, language_id=22`, with series as the website's default tab. For "all genres" with a language, the website sends `category_id=56` | Same |

### Search

| Endpoint | Source | Status | Verified parameters and behaviour | Response |
|---|---|---|---|---|
| `video/V/2/itemsPerPage/{A}/video_title_search/{q}/itemsPerPage/{B}/pageNumber/{p}/level/0` | W C | ✅ `titleSearch()` | Title search across movies and series, with good relevance. The server computes **`urldecode(base64decode(q))`**. **Our encoding** is percent-encode(base64(URL-encode(query))), and it keeps every character (`c++`, `100%`, `%41`, Arabic, CJK, accents, `'`, `&`, `:`). **The website's encoding** is unpadded base64url of the raw text; it works for plain text but **turns `c++` into `c  ` and `%41` into `A`**. A raw `=`/`+` in the path gives 400, and an empty `q` gives `[]`. Only `B` counts (see Paging). The website sends `A=20, B=12`, page 0 only | Media list |
| `AdvancedSearch?level=0&…` | W C A | ✅ `advancedSearch()` | See the filter list below | Media list |

`AdvancedSearch` filters:
- **`type=movies|series`:** the builder requires it, because without it the server returns movies only.
- **`videoTitle` and `staffTitle`:** OR-ed. The results page sends the query in both, and so does `SearchRepository.search`. Arabic names work.
- **`category_id`:** a single ID. A comma list keeps only the lower ID, a name or an unknown ID is ignored (unfiltered results), and `category` returns nothing.
- **`year=from,to`:** the website always sends `1900,<current year>`. A reversed range returns `[]` (the builder swaps it), and a single year is ignored.
- **`page`:** 12 per page.
- **Ignored:** `sort`, `itemsPerPage`, `lang`, `q`, `search`.
- **Excluded:** `star` (minimum rating).

### Media details and playback

| Endpoint | Source | Status | Verified parameters and behaviour | Response |
|---|---|---|---|---|
| `allVideoInfo/id/{id}` | W C A | ✅ `details()` | Every title page and episode switch | The full record (§3) with `actorsInfo`, `directorsInfo`, `writersInfo`, `categories`, `videoLanguages`, `introSkipping`, `translations`, … |
| `transcoddedFiles/id/{id}` | W C A | ✅ `streams()` | Cached by the API (stale answers can hold expired URLs). `?_=<unique>` bypasses the cache | Streams (§3) |
| `translationFiles/id/{id}` | W C | ✅ `subtitles()` | The website calls it only for the special ASS track | Subtitles (§3) |
| `videoSeason/id/{seriesId}` | W C A | ✅ `episodes()` | Pass the series ID. An episode ID also answers, with an incomplete list | All episodes, unsorted |
| `videoSeasonNumber/id/{seriesId}` | W C | ✅ `seasons()` | Can be `[]`; the repository then falls back to the episodes | `[{season: "1"}, …]` |
| POST `https://recommend.shabakaty.com/api/recommendation/recommend` | W C A | ✅ `recommendations()` | JSON body `{MovieId, MovieName?, ReProcessIfExpired: true}`. `MovieId` can be a string or a number; an episode ID gives the same results as its series. `MovieName` and extra fields change nothing | `{movieId, movieName, recommendations: [10–30 media + distance_type ("collection", "staff_at_least_2", "base + genre", "base + genre + group_coll", or null), country, distances, …], expirationDate, temp}`. An unknown ID gives `[]` with `temp: true` |
| `relatedVideos/id/{id}/kind/{k}/level/0` | W | ⚙️ fallback in `recommendations()` | Up to 30 items; `kind` changes the results. The website no longer calls it | Media list |
| `video_thumbnails/video_id/{id}` | W C | ✅ `seekPreview()` | Every title page and episode switch | Sprites (§3) |
| POST `getVideosByIds` | W | ✅ `byIds()` | Form body `ids=[id1, id2, …]` (the brackets are required; `["1","2"]` also works). At most 40 IDs. The response keeps the request order and repeats duplicates. Unknown numeric IDs are skipped, but one non-numeric ID empties the whole response. GET gives 404. The website uses it for guest history | Full records (with subtitle file names) |
| `staff/actorID/{id}/lang/{lang}/level/0` | W C | ✅ `staff()` | Not paged; extra path segments and parameters are ignored. Level 2 hides titles. The APK form `staff/actorID/{id}/level/{level}` (no `lang`) also works | Staff page (§3) |
| `faqQuestion` | W C | ✅ `faq()` | 29 bilingual entries. `porder` is always 0. `categoryName` is in English only ("User Account Management", "Video Options"…) | `[{nb, en_title, ar_title, en_content, ar_content, categoryName, categoryNb, porder, priority, …}]` |

### Service status

| Endpoint | Source | Status | Verified parameters and behaviour | Response |
|---|---|---|---|---|
| `https://6b1m6vnfz2jk.statuspage.io/api/v2/components.json` | A | ✅ `serviceStatus()` | Public, no login or keys. A "Cinemana" group (`group: true`) has the components "API" and "Search Engine" (`group_id` = the group's `id`). The parser takes the worst status of the group and its components (`parseCinemanaHealth`). Call it only after API failures. `summary.json` and `status.json` also exist | `{page, components: [{id, name, status: operational \| degraded_performance \| under_maintenance \| partial_outage \| major_outage, group, group_id, components}]}` |

### Dead, excluded and login-only

| Endpoint | Source | Status | Notes |
|---|---|---|---|
| `skippingDurations/id/{id}` (and `skippingDurations`/`parent_skipping` in records) | W C A | 🚫 | Parental scene skips (`{start: [], end: []}`), not intros. Zero censorship |
| `checkVideoParentalLevel/id/{id}` | W C | 🚫 | Parental check, called on every title page by the website |
| `videoComment/id/{id}/limit/{n}/offset/{n}` | W A | ❌ | Always `[]`. Comments are off server-wide (`showComments: false` everywhere) |
| `collectionsId/`, `collectionsId/level/0` (A), `collectionVideos/collectionID/{id}/level/0` (W C), `getCollection/collectionID/{id}/level/0` (A) | W C A | ❌ | Always `[]`, including the website's `/collections/1` page and the APK's "franchises" endpoint. `collectionID` is `"0"` on every record |
| `popularFilms/…` | W C | ❌ | Always `[]` |
| POST `https://thumbnail.shabakaty.com/api/series/seasonposters` `{RootSeries}` | W C | ❌ | 500 on every series page of the website |
| `rating.shabakaty.com/api/…` (`rating-summary-by-targets-types`, `ratings`, `check-rating`) | W C | 🚫 | Ratings. Needs the bundle's `ShabakatyAppId`, which we never use |
| `api/info/ShabakatyInfo/`, `api/info/userInfo/`, `whatismyip` (×3), `shabakaty.com/clip/`, `hacheckphp.php` | W C A | 🚫 | Telemetry and IP/ISP checks |
| `history`, `continueWatching/level/{l}/itemPerPage/12/page/{p}`, `addToHistory`, `removeFromHistory`, `get_subscriptions`, `add_subscriptions`, `remove_subscriptions`, `get_subscription_status`, `memberCheckVideoStatus/id/{id}`, `addLike`, `increaseNumberOfView`, `highlightEpisode`, `addComment`, `removeComment`, `updateComment` (A), `commentSpam` (A), `reportIssue`, `get_notifications`, `resetNewNotifications`, `notifications` (A), `userSettings/lang/{lang}`, `changeParentalLevel`, `UserTranslationSettings`, `device/login_status` (A), `login`/`logout`/`me` (A), all of `contwatch.shabakaty.com` and `account.shabakaty.com` | W A | 🔒 | Need a Shabakaty login. Never called |

## 5. What the website calls (Chrome traces)

| Page | Requests |
|---|---|
| Home | `banner`, `newlyVideosItems` ("New releases" row), `videoGroups/lang/{lang}`, `mainCategories`, `videoListPagination` (row scrolling) |
| Arabic switch | Re-requests `videoGroups/lang/ar` and `mainCategories?lang=ar`; the layout turns RTL |
| New releases | `latestMovies` page 0 |
| Popular | `popularFilms/kind/M` (empty) |
| Movies / Series | `video/V/2/itemsPerPage/30/…/sortParam/desc/pageNumber/0`, `mainCategories`, `subCategories`, `categoryLangFreqVideo`. A genre uses `videosByCategory` (with a language: `videosByCategoryAndLanguage`), offset +30 on scroll |
| Anime | `categoryLangFreqVideo`, `videosByCategoryAndLanguage` (57 × 22 by default) |
| Search box (while typing) | Title search, `itemsPerPage/20 … /12`, page 0 |
| Search results page | `AdvancedSearch` with `videoTitle=staffTitle=<query>`, `year=1900,<year>`, `type`, `page` |
| Title page | `checkVideoParentalLevel` 🚫, `allVideoInfo`, recommendation, `transcoddedFiles`, `skippingDurations` 🚫, `video_thumbnails`, the `vtt` files, `translationFiles`; series pages add `videoSeason`, `videoSeasonNumber` and `seasonposters` ❌. The URL is `/video/{lang}/{id}`, with `?lastEpisodeVideoID=` for a specific episode |
| Episode switch | `allVideoInfo`, `transcoddedFiles`, `skippingDurations` 🚫, `video_thumbnails` for the episode |
| Player | Default quality 480p (`localStorage['latest-quality']`). The quality switch keeps the position; the subtitle menu offers Arabic and English (`vtt`); the Skip Intro button jumps to the range end |
| Group "see all" | `videoListPagination`, page +1 on scroll |
| Staff | `staff/actorID/{id}/lang/{lang}/level/0` |
| FAQ | `faqQuestion` |
| Settings (guest) | Login wall only |
| Collections | `collectionVideos` (empty) |
| Everywhere | 🚫 telemetry: `ShabakatyInfo`, Sentry, Yandex, New Relic, ratings |

## 6. The Android app (5.3.3)
The app is native Kotlin (Retrofit/OkHttp, ExoPlayer). It was removed from Google Play in 2019 and is now distributed through Shabakaty's site and APK mirrors. Its dex strings show:
- the same endpoints as the website, often in query form (`video/V/2` with `@Query` parameters);
- `staff/actorID/{id}/level/{level}` without `lang`;
- `collectionsId/level/{level}` and **`getCollection/collectionID/{id}/level/{level}`** ("franchises"), both empty;
- comment, notification, device-login and account endpoints (🔒);
- Zendesk support SDK paths (`/api/mobile/…`, `/api/v2/help_center/…`) and a public status page (`6b1m6vnfz2jk.statuspage.io`);
- telemetry, ads (Epom via `aj2376.online`), OneSignal and `api.ipify.org` (🚫).

It has no endpoint the website lacks that returns data. App IDs, keys and tokens in it were not used or copied.

## 7. Keeping this reliable
- **The parsers never throw.** They skip bad records, and `tool/api_contract_check.dart` checks that no *valid* record is skipped (parser yield = raw count). It also checks every behaviour this file documents and the code relies on: search encoding and page size, `AdvancedSearch` semantics, sort codes, paging ends, stream freshness, styled subtitles, sprite geometry, placeholders, banner links, intro ranges and the status page.
- **Fixtures are real responses** (lists trimmed to 6 items, signed URLs redacted). Parser tests run against them, plus inline edge cases. `series_episodes_finale` / `series_episodes_double` (Lucifer, One Piece), `subtitles_special` / `video_info_special` and `thumbnails_broken` (816721) use fixed long-lived IDs. `staff_no_photo` is discovered.
- **When the API changes:**
  1. Run the contract check.
  2. Re-capture the fixtures and diff them.
  3. Update this file, the parsers and the tests together.

## 8. Open questions and decisions
**Closed in this deep dive:**
- **Android app:** analysed (§6). There is nothing new to use.
- **Fields:** `introSkipping.control_level` (always `"3"`, meaningless) and `episode_flag` (episode labels) are explained. `audioStreamNumber` is a meaningless counter (one audio track per file). `isSpecial`, `orderNmmer`, `replacement`, `watermark`, `useParentImg`, `fileSize*`, `channels` and `translationFlag` are meaningless or absent. `published`, `itemDate` and `updateDateTime` are upload timestamps. Group `analytics` is telemetry.
- **Sort codes:** all 12 of the website's keys were mapped (§2). There are no hidden ones.
- **2160p:** real 3840-wide 8-bit H.264 (~22 Mbit/s, 98%) or occasional 8-bit HEVC (18–20 Mbit/s, ~2% of 2026 titles), fast-start, byte ranges work.
- **HDR / Dolby Vision / Dolby Atmos (2026-11-26):** no real 10-bit HDR10, Dolby Vision, or Atmos/surround streams exist across 210 probed live streams (833 titles surveyed); everything is 8-bit `yuv420p` with AAC-LC 2.0 stereo, with only ~1% of titles unintentionally passing through `BT.2020` + `PQ`/`HLG` `colr` tags in 8-bit H.264 across all resolutions (§3).
- **Other formats:** there is no HLS or DASH, and no multi-audio.
- **Subtitles:** only Arabic and English plain tracks exist, plus the styled Arabic ASS track (`spTranslationFile`). There is at most one per language and format.
- **Staff lists:** not paginated. Counts differ simply by filmography (up to about 40).
- **Banner `link`:** `showInfo` (details or player) and `lastEpisodeVideoID` (the episode to open), on `.com` or `.cc`.
- **`category`:** the union of main and sub genres plus `0`, with no hierarchy.
- **`videoLanguages`:** always an object.
- **Caching:** measured per endpoint (§2). Stable IDs: the old IDs from the first deep dive (Friends 4328, Avengers 191463) still resolve. Signed URLs: §3.

**Still open (low risk):**
- Why `allVideoInfo` answers an empty 200 for a few series roots (e.g. 1184051) whose episodes still play. The app shows them as unavailable.
- How often the API cache serves expired stream URLs. It was seen on 13 of 1,037 files, and the repository handles it.

**Product decisions (made 2026-11-19, see `docs/PLAN.md` §4):**
1. **Title sorts (A→Z, Z→A):** only on genre pages; the "All" lists don't offer them.
2. **Styled ASS subtitles:** offered as an extra "Arabic (styled)" choice. Plain Arabic stays the default, and one Arabic fallback font is shipped for libass.
3. **Search by actor:** kept. The query is sent as both title and staff name, like the website.
4. **Service status:** the status page is checked only after API calls fail, to show "Cinemana is having problems" instead of a generic error.
5. **4K:** treated like any other quality (no special limits).
