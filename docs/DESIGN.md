# Cinemakom Design: "Marquee"

**The idea:** the neighbourhood picture palace after dark. The interface is deep cocoa and warm bulb light, so the **posters are the only real colour on screen**. It nods to the old cinema halls of Al-Rasheed Street without turning into a costume.

**One theme.** There is no light mode, dark mode or theme setting. Every colour, size and radius comes from the tokens below (`lib/app/theme/`). Never hardcode a colour or font in a widget.

Visual reference: the [design canvas](https://claude.ai/artifact/XEb3j3VhiknZVEpX4FuLnU). The "Design directions" page holds the Marquee system and logo boards; the "App screens" page holds every screen in §8.

---

## 1. Colour (`MarqueeColors`)

| Token | Hex | Use |
|---|---|---|
| `night` | `#15100C` | App background |
| `screen` | `#000000` | The player's backdrop behind the video (true black for OLED letterbox bars) |
| `booth` | `#221A14` | Surfaces: panels, sheets, cards, search field |
| `boothRaised` | `#2C221A` | Selected or hovered rows, pressed surfaces |
| `navBar` | `#1B1510` | Bottom bar and rail |
| `velvet` | `#3A2C21` | Dividers, outlines, progress tracks |
| `velvetStrong` | `#5A4634` | Outlined-button borders, inactive indicators |
| `cream` | `#F4EAD7` | Primary text and icons |
| `creamSoft` | `#CDBEA5` | Long text (synopsis) |
| `dust` | `#B9A88E` | Captions, metadata, inactive nav |
| `dustDim` | `#6E5C47` | Decorative only: unwatched episode numerals, disabled |
| `bulb` | `#F4B740` | **The one accent**: primary actions, active nav, progress, focus, 4K badge |
| `bulbBright` | `#FFD27A` | Pressed or hovered accent |
| `onBulb` | `#1A1208` | Text and icons on `bulb` |
| `ember` | `#E8735A` | Errors only |

Rules:
- **Bulb is scarce.** Use it on at most one primary action per screen, plus indicators (active tab, progress, focus). It is never a background for large areas.
- **No gradients, shadows or blur.** Surfaces are separated by tone (`night` → `booth` → `boothRaised`). The one exception is a `night` scrim under text that sits on artwork.
- **Contrast** (checked by `test/theme/contrast_test.dart`): `cream`, `creamSoft`, `dust` and `bulb` are all ≥ 4.5:1 on `night`, `booth` and `boothRaised`, and `onBulb` is ≥ 4.5:1 on `bulb`. `dustDim` is decorative only.

## 2. Type (`MarqueeText`)

| Role | Latin | Arabic |
|---|---|---|
| **Display** (hero titles, section headers, numerals, logo) | Big Shoulders Display 800–900 | Reem Kufi 700 |
| **UI** (everything else) | IBM Plex Sans 400/500/600 | IBM Plex Sans Arabic 400/500/600 |

Each role is one family plus a fallback (`fontFamilyFallback`), so mixed-script titles (very common in the API) render with the right glyphs without any locale switch.

| Style | Size / line height | Weight | Notes |
|---|---|---|---|
| `heroTitle` | 58 / 0.9 | Display 900 | Latin titles uppercased. On the Home hero, `HeroTitle` steps it down to fit (§8) |
| `displayLarge` | 40 / 1.0 | Display 800 | Details title |
| `sectionTitle` | 22 / 1.1 | Display 800 | Latin: uppercase, tracking 0.04 em |
| `numeral` | 34 / 1.0 | Display 900 | Episode numbers ("04") |
| `title` | 16 / 1.3 | UI 600 | Card and row titles |
| `body` | 15 / 1.5 | UI 400 | Synopsis (`creamSoft`) |
| `label` | 14 / 1.2 | UI 600 | Buttons |
| `caption` | 12 / 1.35 | UI 400 | Metadata (`dust`) |
| `eyebrow` | 12 / 1.2 | UI 600 | "NOW SHOWING": tracking 0.16 em, `bulb` |
| `navLabel` | 11 / 1.2 | UI 500, 600 when active | |

**Media titles are script-aware.** A title can be Arabic even in the English UI (the API often puts Arabic in `en_title`). Style titles with `heroTitleFor(title)` / `displayLargeFor(title)`: Arabic display glyphs (dots, tall ascenders) need a line height of about 1.3 where Latin capitals use 0.9. The fonts are bundled in `assets/fonts/`. The variable fonts get their weight through `withWeight()`, which also sets the `wght` variation.

**Arabic rules.** Arabic is cursive, so **never apply letter-spacing or uppercase to Arabic**. Tracked styles (`sectionTitle`, `eyebrow`) drop their tracking in the Arabic locale, and media titles carry no tracking at all, because they can be in either script. Arabic line height is at least 1.5 for body text.

**Metadata format:** `year · genre · length` (e.g. `2023 · Drama · 3h`). There are no ratings anywhere (AGENTS.md). Numbers and durations are formatted with `intl` for the active locale, but always with **Western digits (0–9)**, in Arabic too (`2024 · خيال علمي · 2 س 46 د`). *Decision 2026-11-19.*

## 3. Space, shape, motion

- **Spacing:** multiples of 4 (`4 8 12 16 20 24 32 40`). Screen gutter: 20 on phones, 32 at 600 dp and up, 48 at 1200 dp and up.
- **Radii:** 6 thumbnails · 10 posters · 12 rows, cards and hero banners · 16 panels · pill for buttons (height / 2).
- **Touch targets:** at least 44 × 44. The primary button is 48 tall.
- **Motion:** 150 ms ease-out for state changes and 250 ms for page transitions. Nothing loops except the loading indicator, and the only thing that moves by itself is the Home hero carousel (a 10 s timer, no frames in between). Respect `MediaQuery.disableAnimations`.

## 4. The motif: marquee bulbs

A row of small `bulb` dots (4–6 px, gap 5–7 px, with an occasional dimmed dot) has three uses:
- **The loading indicator:** dots light in sequence. It replaces spinners and shimmer.
- **The hero pager:** a centred row of bulbs above the banner, one per banner, the current one lit.
- **Brand marks:** the logo, the splash screen and the header.

Use it sparingly. It is never a divider between every section.

## 5. Components

- **Poster card:** 2:3 image, radius 10, `title` below (1 line, ellipsis), then a `caption` with year · genre. The only badge is **4K** (`bulb` background, `onBulb` text, radius 4, at the top start corner). The placeholder is a plain `booth` block (no shimmer). Keyboard focus draws a 2 px `bulb` ring. *Lists don't say which titles have 4K (only a title's streams do), so the badge can only appear where streams are loaded.*
- **Hero (Home):** the first 10 banners (`heroBannerCap`; the API sends 85). No panel. A centred bulb pager (one bulb per banner: `bulb` for the current one, `velvetStrong` for the rest; a tap goes to that banner, the short way round). The carousel loops: after the last banner the first comes in next, the same way, and you can swipe either way forever. The bulbs shrink (pitch 19 → 12 dp, size 7 → 5 dp) so every banner gets one and the lit bulb walks along the row; when even that doesn't fit, the row shows a page of bulbs at a time. Then a carousel of **wide banner covers at their real 2.7:1 ratio** (radius 12). On phones each banner is 90% of the width from the start gutter, so the next one peeks in at the end edge, and a banner fades as it slides out past the start; from 900 dp the carousel takes 60% beside the text, one banner at a time. Under it: `eyebrow` "NOW SHOWING", the title (`HeroTitle`), `caption` meta, then **Play** (primary) and a Favorite icon button. **The title** takes the biggest step that shows it whole without breaking a word: one line at 100% or 85% of `heroTitle`, two lines at 72%, 60% or 50%, three lines at 50% or 42%; lines are balanced. Only a single word too long for any step gets an ellipsis. The text block is as tall as the tallest banner's text and bottom-aligned, so the page below never shifts and Play stays in place. The old text fades out, then the new one fades in (300 ms). It advances every 10 s; it holds under a finger, while Home is hidden and with `disableAnimations`.
- **Continue card:** `booth` row (radius 12, padding 8) with a 56 × 84 poster, title, "Season 2 · Episode 5", a 3 px progress bar (`velvet` track, `bulb` fill) and "14 min left".
- **Episode row:** `numeral` (bulb when in progress, `cream` when watched, `dustDim` when unwatched), then "Episode N" (the API has no episode titles), length, and progress when started. The current episode sits on `boothRaised`.
- **Long seasons:** a season of more than 50 episodes (One Piece is one season of 1,179) gets a second row of range chips under the season chips ("1–50", "51–100", …, from the episode numbers), so at most 50 rows sit between the episodes heading and Cast and crew. The list opens on the block of the episode playing, else the one watched last, and scrolls that chip into view. The numeral column is as wide as the widest number in the block shown (at least 52), so "1179" stays on one line and the labels line up.
- **Buttons:** primary = `bulb` pill, `onBulb` label with an icon. Secondary = outlined pill (`velvetStrong` border, `cream` label). Icon button = 44 px circle, `booth` fill, `velvet` border.
- **Section header:** `sectionTitle` at the start edge, a "See all" link (`bulb`, `label`) at the end edge.
- **Navigation:** five destinations: **Home · Search · Library · Downloads · Settings** (*decision 2026-11-19*). Library holds Continue watching and Favorites. On Android TV the UI is separate, with top tabs instead (`docs/TV.md` §6–7).
  - Below 600 dp: bottom `NavigationBar` (`navBar`, height 72, top border `boothRaised`).
  - 600–1199 dp: `NavigationRail` (`navBar`, end border `boothRaised`), small mark at the top, labels under the icons.
  - 1200 dp and up: extended rail, 232 wide, with the mark and CINEMAKOM at the top and labels beside the icons.
  - Active item: a `boothRaised` **pill** behind the icon (the built-in indicator, `indicatorColor` + stadium shape), with a `bulb` icon and label at weight 600. Inactive: `dust`, weight 500.
- **Segmented control** (Library, Genre kind): `booth` track (pill, padding 4), the selected segment is a `boothRaised` pill with a `cream` label at 600; the others are `dust` at 500.
- **Filter chips** (search kind, seasons, languages): 32–36 tall pills. Selected = `boothRaised` fill, `velvetStrong` border, `cream` label. Unselected = transparent, `velvet` border, `dust` label.
- **Settings row:** 56 tall inside a `booth` group (radius 12), `velvet` divider between rows, label at the start, value in `dust` and a chevron at the end. Group headings are 12 px, 600, tracked, `dust`.
- **Icons:** outlined, 1.8 px stroke, 22 px in navigation and 18 px in buttons.

## 6. Performance rules
- **Image sizes:**
  - **Lists** use `imgMediumThumbObjUrl` (293 × 439, ~40 KB). *Android TV is the exception: its cards swap in the original once they're on screen, so posters stay sharp on 4K panels (`docs/TV.md` §9.1).*
  - **Details** use `imgObjUrl` (2000 × 3000, ~1.5 MB) **only** with `memCacheWidth` = displayed width × device pixel ratio.
  - **The hero** uses the banner cover, decoded at screen width × device pixel ratio.
- **No** `BackdropFilter`, shadows, `Opacity` animations over images, or `saveLayer` effects. Round images with `ClipRRect` only where needed, and everything else with `BoxDecoration.borderRadius`.
- **Lists:** horizontal rows use `ListView.builder` with a fixed `itemExtent` where possible. Use `const` widgets wherever possible.
- **Refresh rate (Android):** `MainActivity` asks for the display's fastest mode at the current resolution (`preferredDisplayModeId`). Without it, OnePlus/OPPO (ColorOS) and some other vendors hold apps that aren't on their allowlist at 60 Hz on a 120 Hz panel. It is only a preference: battery saver, thermal limits and the user's refresh setting still cap it. The frame budget is therefore **8.3 ms**, not 16.7 ms. TVs are the exception: there a display mode is an HDMI output mode, so `MainActivity` doesn't ask, and the budget is 16.7 ms (`docs/TV.md` §9). Check with `integration_test/scroll_perf_test.dart` (see AGENTS.md).
- **Fonts:** bundled in the app (no runtime downloads), each with its SIL OFL text in `assets/fonts/licenses/`, registered on the licenses page (`registerFontLicenses` in `main.dart`). Variable fonts where available; for IBM Plex Sans Arabic, only Regular, Medium and SemiBold.

## 7. Logo (final: mark 1, "Ticket")

**The mark** is a solid `bulb` ticket stub with **ك** knocked out of it. ك is the "your" in سينماكم: *your* ticket, *your* cinema. The letter is traced from Reem Kufi Bold, so the logo never depends on a font. The font draws ك as two overlapping contours; the generator merges them into one outline before knocking it out, because the even-odd fill would otherwise turn their overlap back to solid (a stray triangle). It has three levels of detail, chosen by size (`CinemakomMark.detailFor`):

| Detail | Size | Shows |
|---|---|---|
| `full` | ≥ 48 px | ticket, ك, perforation |
| `small` | 24–47 px | ticket, larger ك |
| `tiny` | < 24 px | the ticket silhouette (bolder notches) |

**The lockup** is the mark next to **CINEMAKOM** (Big Shoulders Display, cream) over **سينماكم** (Reem Kufi, `bulb`). In the Arabic UI the order flips, with سينماكم leading. Widget: `CinemakomLogo`.

**In the app**, draw it with `CinemakomMark` (`lib/app/brand/`). It's a `CustomPaint` over generated paths: sharp at any size, with no SVG package and no image decoding.

**One source for everything.** Run `python3 tool/brand/generate.py` (needs fontTools, rsvg-convert and ImageMagick) and it regenerates every output. **Never edit these by hand:**

| Platform | Output |
|---|---|
| Masters | `branding/*.svg`, `branding/store/play-store-512.png` |
| Android | adaptive icon (Night background, ticket scaled into the 66 dp safe zone), **monochrome** layer (themed icons), legacy mipmaps, Android TV home-screen banner (`drawable-xhdpi/tv_banner.png`, 640×360: the English lockup on Night, its names set in the bundled fonts), Android 12+ splash (`values-v31`) and the older launch background. There is one theme only, so no `values-night` |
| Windows | `windows/runner/resources/app_icon.ico`: 16, 24, 32, 48, 64, 128 and 256 px, transparent, no tile |
| Linux | `linux/packaging/icons/hicolor/**` (16–512 px + scalable SVG), `linux/packaging/io.github.sharon_xa.cinemakom.desktop`, and the window icon `assets/brand/app_icon_256.png` (set in `linux/runner/my_application.cc`) |
| Flutter | `lib/app/brand/brand_paths.g.dart` |

To change the logo, edit the geometry in `tool/brand/generate.py`, then run it.

## 8. Screens

Drawn on the canvas's "App screens" page (*decisions 2026-11-19*). Every tab screen opens with its name in `displayLarge` at the start edge, except Home, which opens with the logo lockup.

- **First launch:** the large mark and lockup, "Choose your language / اختر لغتك", two option cards (English in the Latin display face, العربية in Reem Kufi; selected = 2 px `bulb` border and a filled radio), then **Continue**. Picking Arabic flips the screen to RTL straight away. Caption: "You can change this later in Settings."
- **Home:** lockup header (no search icon, since Search is a tab), hero, Continue watching, then the poster rows from PLAN.md §4.1. Each row has a "See all" link.
- **Search:**
  - Field at the top (`booth` pill, 48 tall, `bulb` border while focused, clear button), then kind chips (All · Movies · Series) and a **Filters** button that opens the advanced filters (Phase 7, with the advanced search).
  - Before typing: **Recent searches** (when there are any) above the genres: a section header with a "Clear all" text button, then up to 10 rows (history icon, the query in `cream`, an ✕ to remove that one). A row searches again. A search is remembered only when meant: the keyboard's search key, a recent search, or a title opened from its results, never the searches made while typing. Stored on the device, newest first, no duplicates.
  - Before typing: a two-column **genre grid** (`booth` tiles, 64 tall). A tile opens that genre's page.
  - Results: the title grid (3 columns or more on wide windows), infinitely scrolling. The kind chips filter it. Titles also match by cast or crew name. *There is no People row: the API has no people search, and list items carry no cast (2026-11-19).*
- **Genre:** back button and genre name, a Movies | Series segmented control, a sort button ("Recently added ▾") at the end, language chips (the genre × language filter), then the 3-column grid with infinite scroll.
- **Details:** a **full page** pushed inside the current tab, so the nav stays visible. It is not a bottom sheet, because related titles and people open further pages and back must step through them.
  - Back button, then the poster (128 × 192) beside the title, meta, audio language and the external link. The poster is aligned to the top, so a long title grows downwards beside it; the title (`WordFitTitle`) steps its size down rather than break a word in half.
  - Primary button (Play, or "Resume · S2 E5 · 14 min left"), then Favorite and Trailer as secondary pills.
  - Synopsis, genre chips (each opens the genre page), the season chips and episode rows (§5), Cast and crew, More like this.
  - On desktop the same content sits in two columns.
- **Person** (actor, director, writer): pushed inside the tab from Cast and crew. Back button, then a 96 px round photo (or initials) beside the name (`displayLarge` at 30, Latin uppercased) and a `caption` with the role · "31 titles". Below, the 3-column poster grid of every title they're credited on, newest first. The API sends it all at once, so there's no paging. The role is the one they were tapped as; the server's own role is only a fallback, because one person can have several staff IDs.
- **Library:** a [Continue watching | Favorites] segmented control. Continue is a list of continue cards (full width on phones, columns of about 560 dp on wide windows, with a play button; a finished episode shows the next one as "Up next" in `bulb`, with its length and no bar). Here a card opens the title and the play button plays; on Home the card plays. A long press or right click offers "Remove from Continue watching". Favorites is a 3-column poster grid, the last added first. Empty shelves say what goes there in `body`, centred.
- **Favorite:** a bookmark, filled in `bulb` once saved. A secondary pill on Details ("Favorite" / "In favorites"), a 44 px icon button beside the hero's Play.
- **Downloads:** "4.2 GB used by Cinemakom" in `caption` (finished files plus what unfinished ones have so far), then **Downloading** and **On this device** (*built 2026-11-19*). Rows are `booth` cards (radius 12) with a 48 × 72 poster.
  - *Changed:* no storage bar and no free space. There's no reliable way to read free space on every platform, and a bar of "used" alone means nothing. A download fails with "Not enough space on this device" when less than 500 MB would be left.
  - **Downloading:** title, "Season 1 · Episode 2", the 3 px progress bar, then two caption lines: "1.3 GB of 3.0 GB" and "4 MB/s · 7 min left". The bar spans the row on a `velvetStrong` track, so what's left shows. Waiting, Paused and failed ones say so (a failure in `ember`). Pause (or Resume, or Try again for a failure) and Cancel at the end; Cancel asks first ("Cancel this download? What's downloaded so far is lost.").
  - **On this device:** a movie row ("720p · 270 MB") plays on tap and has a `bulb` play icon. A series is one row ("3 episodes · 270 MB") with a chevron, opening its episodes (each plays on tap; "…" offers Play and Delete download), with **Delete all episodes** at the bottom (asks first). A long press or right click on a movie row opens the same menu; on a series row it offers Delete all episodes.
  - **RTL:** "720p · 270 MB"-style captions join their parts with `context.joinMeta` (bidi isolates in Arabic), or the Latin quality and the number swap places.
  - **Details:** a movie gets a Download pill (DESIGN §5 secondary) after Favorite: "Download", then "Waiting", "Downloading · 42%" with a progress ring, "Paused", the problem, or "Downloaded" with a `bulb` check. Episode rows get a 40 px download button in the same states, and **Download season** sits above the rows. Download asks for the quality first, with sizes ("1080p · 2.9 GB", the Settings quality marked); a season shows "about 600 MB each".
  - **Settings (desktop):** a Downloads group with the folder; new downloads go there, finished ones stay where they are.
- **Settings:** groups General (Language; on phones and tablets also Screen rotation: **Rotate with device** by default, which follows the system auto-rotate, or **Portrait only**), Playback (Default quality, Default subtitles, Subtitle size), Help (Questions and answers from Phase 7; Report a bug, which asks By email (easiest) or On GitHub (needs an account) and opens the mail app or GitHub's bug form (`.github/ISSUE_TEMPLATE/bug_report.yml`) filled in with the version and device, `lib/features/settings/report_flow.dart`; Cinemakom on GitHub; Activity log, the on-device log with Share the log on phones or Save a copy on computers, and Clear, `ActivityLogScreen`; About and licenses). Desktop adds a Downloads group with the folder (Phase 6). Choices open a bottom sheet below 600 dp and a dialog from 600 dp (`showChoicePicker`): one row per choice, the current one in `bulb` with a check. The mark and app name sit at the bottom (the version comes in Phase 8).
- **Player** (landscape, controls over a 60 % `night` scrim):
  - Top bar: back, title and "Season 2 · Episode 5", then chips for **subtitles, quality (always visible, e.g. "1080p" or "4K"), speed** and fit.
  - Centre: back 10 s, a `bulb` play/pause circle, forward 10 s.
  - Bottom: **Skip intro** (outlined pill, only during an intro range) above the seek bar (`bulb` played, `velvetStrong` buffered), with elapsed and remaining time and **Next episode**.
