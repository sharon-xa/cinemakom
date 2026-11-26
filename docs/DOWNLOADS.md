# Downloads: the reliability plan

> **Status (2026-11-22):** D0 findings confirmed; D1–D6 merged (PR #4); its review list (`docs/DOWNLOADS_TODO.md`) fixed except the TV Details item (13, a design question). Awaiting on-device phone verification (D1 30-min check, D5 on the phone, D6 notification check, D7 release checklist). **Read it before touching `lib/core/downloads`, `downloads_repository.dart`, `download_store.dart` or the Downloads screens.**

The goal: **a download the user starts always finishes**, whether the app is open, in the background or killed, and whatever happens to the network. When it can't finish, the app says why, shows how much is saved, and continues from there. The app never leaves stray files behind, and the finished video is the user's: they can see it in their file manager and do what they like with it.

## 1. What the owner saw (2026-11-21, OnePlus CPH2423, Android 15, release APK)

1. **"Paused" while data is still arriving.** A movie downloading while the app was in the background showed "Paused", while the status bar showed about 10 MB/s coming in. A second try worked, so the bug is intermittent.
2. **The notification has too little information and feels unreliable.** It shows only the title and a bar.
3. **"Stopped: no connection" on working Wi-Fi.** The download stopped by itself, and **Retry couldn't continue it**. The progress bar was empty.
4. **"Paused · 1 MB of 27 GB" after 3.6 GB had downloaded.**
5. **The app uses 11.5 GB of storage ("Data"; cache 2.4 MB)** for one 3.6 GB partial download. Space is lost every time a download fails.
6. The owner's wishes: use a well-maintained, battle-tested library rather than reinventing the wheel, and **let the user see the downloaded videos in their file manager**.

## 2. Decisions *(2026-11-21)*

| # | Decision | Why |
|---|---|---|
| 1 | **Keep background_downloader** (9.6.x, actively maintained: 9.6.4–9.6.6 fixed issues up to #733). Fix how we configure and wrap it. | It's the most complete Flutter download library: Android, iOS, Linux and Windows, custom headers, pause and resume, resume with a new URL, notifications, a native holding queue. The bugs in §3 are in our setup and our wrapper, apart from one documented duty (temp files, §3.3) we never did. Alternatives in §11. |
| 2 | **Every Android download runs as a foreground service** (`Config.runInForeground: always`). | It removes the 9-minute and 2-minute background limits that cause problems 1 and 3 (§3.1). A foreground service needs a notification, and we always show one. |
| 3 | **Finished files go to the public `Movies/Cinemakom` folder on Android** (the owner's choice). | File managers, video players and the gallery see them. They stay if the app is uninstalled. |
| 4 | **Progress is saved in the database**, not only kept in memory. | A paused or failed download always shows how much is saved (problem 4). |
| 5 | **The app cleans up after the engine**: stray temp files, half-written videos, empty folders. | The library's docs require it with `useCacheDir: never` (§3.3). |
| 6 | **Retry continues from the partial file** whenever one exists, and only starts over when the server or the file makes that impossible. The UI says when it starts over. | Problem 3. |
| 7 | **The state shown is the engine's real state**, checked again whenever the app returns to the foreground. | Problem 1. |
| 8 | Unchanged from Phase 6: at most 2 at once, any network (no Wi-Fi-only setting), quality asked each time, subtitles saved beside the video. | |

## 3. What is wrong today (root causes)

Found by reading our code and the library's source (`~/.pub-cache/hosted/pub.dev/background_downloader-9.6.6`). D0 (§8) confirms them on the phone with `adb logcat` before anything changes.

### 3.1 Android stops long background downloads after a time limit

- We give tasks `TransferHint.userInitiated` (priority 0) and `largeFile` (`background_file_downloader.dart:134`). On Android 14+ this runs the task as a **UIDT job** (user-initiated data transfer), which has no time limit, but **only if Android allows it**. The library's docs warn that Android 14+ may refuse to schedule UIDT jobs while the app is in the background. That happens to every task the holding queue starts after another one finishes, and to every re-enqueue.
- When UIDT is refused, the task runs under **WorkManager**. Priority 0 counts as *expedited*, which has a **2-minute** limit (9 minutes otherwise) (`TaskRunner.kt`: `expeditedTaskTimeoutMillis`).
- On timeout, `DownloadTaskRunner.timeoutResult` saves the partial file, re-enqueues the task to resume in 1 s, and **reports `paused`**. Our code then shows "Paused", and the notification switches to its paused form, while the new run is already downloading. **That's problem 1.**
- If the re-enqueue fails, the task **fails with "Task timed out"** (an `ExceptionType.connection`, no HTTP code), which we show as **"no connection"** (`downloads_repository.dart:600`). **That's problem 3.**
- Every timeout also restarts the notification (problem 2).

### 3.2 Our state handling makes it worse

- **Progress is ignored while a row is `paused` or `failed`** (`downloads_repository.dart:515`). The `paused` from a timeout can arrive after the next run has started, and then the row stays "Paused" while data flows. Nothing ever corrects it.
- **Progress lives only in memory** and is dropped on every pause, failure or cancel (`_setProgress(..., null)`, lines 551–565). The screen then computes `total × 0`, which `formatBytes` rounds up to "1 MB" (`downloads_screen.dart:172–178`). **That's problem 4**, and the empty bar in problem 3.
- **The real state is only read at startup** (`_reconcile`, line 149). Coming back from the background never re-checks.
- **Failure labels are guesses**: any failure without an HTTP code is "network", and a task the engine no longer knows is "network" too (line 155).
- **Retry can't continue.** A final `failed` clears the library's resume data (`base_downloader.dart`, `processStatusUpdate` → `_clearPauseResumeInfo`, because `failed` is a final state). Our `resume()` then gets `false`, so we `enqueue` from zero (`_resume`), and `enqueue` deletes the old record first (`background_file_downloader.dart:143`). **That's problem 3**, and it feeds problem 5.
- **A download still waiting in the holding queue can't be paused**: the engine's `pause` returns `false` for it, so the Pause button does nothing.

### 3.3 Temp files are never deleted (problem 5)

- Android partial files are `com.bbflight.background_downloader<random>` in the app's private `files` folder, because we set `useCacheDir: never` (`background_file_downloader.dart:38`). That's the right choice for multi-GB files, but **the library's CONFIG.md says the app must then clean up stray temp files itself**. We never do.
- A failure that could resume keeps its temp file (`prepResumeAfterFailure`). When the failure is final, the resume data is cleared (§3.2), so **nothing refers to the file any more and it stays forever**. Each Retry starts a new file from zero. Three tries of a 27 GB movie can fill the phone.
- Cancelling or deleting a failed download doesn't remove its temp file either: `cancelTaskWithId` only deletes temp files of *paused* tasks that still have resume data.

### 3.4 Finishing copies the whole file

The temp file is on internal storage (`/data/user/0/…/files`) and the destination is on shared storage (`/storage/emulated/0/Android/data/…/files/Downloads`), which is a different mount. `Files.move` fails across mounts, so the library falls back to **copying the whole file** (`DownloadTaskRunner.kt`, "Cross-device link"). For 27 GB that needs twice the space, takes minutes, and an interrupted copy leaves a half-written video behind. The free-space check (`checkAvailableSpace`, 500 MB reserve) doesn't count the copy.

### 3.5 The notification

One global configuration (`configureNotification`, `background_file_downloader.dart:103`) whose running text is only `{displayName}`. It has no size, percent, speed or time left, no clear Pause or Cancel buttons, and a tap does nothing useful. Its "paused" form appears on every timeout (§3.1).

### 3.6 Checked (2026-11-21, D0)

- **"27 GB" for The Odyssey (2026) (`id=3156005`, 2h 52m 35s):** confirmed against the live CDN (`Content-Range: bytes 0-0/28611233360` = 26.65 GiB, rounded to 27 GB by `formatBytes`; 1080p is 3.20 GiB). `ApiClient.contentLength` is accurate, and the free-space check handles 25–30+ GB files.
- **WorkManager fallback:** `dumpsys jobscheduler` on the OnePlus CPH2423 (Android 15) confirmed past WorkManager Expedited Job (`Timer<EJ>`) sessions (up to 146.9 s) for `io.github.sharon_xa.cinemakom`, matching §3.1.
- **Resume data after final `failed` (D3 check):** verified in `background_downloader-9.6.6/lib/src/base_downloader.dart` (`processStatusUpdate`): `_clearPauseResumeInfo` is called unconditionally on `update.status.isFinalState` before emitting the update, with no opt-out flag. Keeping network trouble from becoming final (`retries: 10` + connectivity pause on offline) plus honest `startedOver` restart is the intended design (§5.5).
- **Android notification buttons (D6 check):** `background_downloader` localizes Pause/Resume/Cancel via `bg_downloader_pause` / `bg_downloader_resume` / `bg_downloader_cancel` string resources (`values/strings.xml` and `values-ar/strings.xml`), and supports `{progress}`, `{networkSpeed}`, `{timeRemaining}` in `Notifications.kt`.

### 3.7 A failed finishing copy starts the whole file over *(2026-11-26, found by the memory test)*

On desktop, once the bytes are in, background_downloader copies the temp file into place (`download_isolate.dart`, `File(temp).copySync(filePath)`). If that copy throws, the task counts as failed **with resume data for a temp file that is already complete**. The library's retry then asks for the range past the end, which the server refuses, and the download **starts over from 0**: up to 10 times (`retries: 10`), each a full download. Seen with a 3.3 GB 1080p file and a destination the app couldn't create (the memory test's mistake: a relative folder, which the downloader reads from `/`); each failure looked like `running -> queued` at 99%, and the error is only in the library's own log (debug builds: `PathAccessException … Permission denied`). Nothing in the app reports it: the retry's status update carries no exception.

How a user could hit it: the destination stops being writable, or the disk fills up between the start's free-space check (which counts the copy, `needsCopy`) and the finish. Both are rare on desktop, where the temp file sits in the destination's `.partial` folder. Not fixed yet. A fix would stop retrying a task whose temp file is already its full size (finish it from the temp file, or fail it as *can't write* with **Retry**), and test it on Linux with a destination made read-only near the end.

## 4. The rules (what must always be true)

These are the contract. Each one gets a test (§9).

1. **One download = one row = at most one engine task = at most one partial file.** A new attempt removes the old task, its resume data and its temp file first.
2. **The shown state follows the engine, except for what the user decided.** Progress arriving means *downloading*, unless the user pressed Pause. Only the user, or a final failure, makes a download stop.
3. **Saved progress is never lost.** Downloaded bytes and the total are stored, and every state shows them ("Paused · 3.6 of 27 GB").
4. **A `paused` the app didn't ask for is not a pause yet.** It's shown as *downloading* (after the engine's time limit the next run follows within seconds), and a guard asks the engine again after 8 s: still paused means the notification's Pause (the user's pause, resumable); unknown to the engine means *interrupted*. *(Changed 2026-11-22: was 60 s and always "interrupted", which turned every notification Pause into a failure; PR #4 review, critical 4.)* **The last percent is watched the same way:** from 99% on, if the engine goes quiet for 8 s, the same guard first asks it for status updates it couldn't hand over (`sync()`, background_downloader's `resumeFromBackground`), then checks its state, and keeps checking every 8 s while it's still moving the file. *(Added 2026-11-22: on the TCL a 3.4 GB movie stayed at 99% until the Downloads tab's re-check fetched its `complete`, which had been kept on the native side.)*
5. **Retry continues from the partial file** if one is valid, with a fresh signed URL. Starting over only happens when the server refuses the range or the ETag changed, and the UI then says "Started over".
6. **Every failure has its real reason**: no connection, link expired, not available, storage full, can't write, interrupted, server error.
7. **Nothing is left behind.** After a delete, a cancel, a final failure, a quality change or a finish, the only files left are the finished video and its subtitles. Startup and app resume sweep away anything stray.
8. **The finished file belongs to the user.** It's in a public folder. If they move, rename or delete it outside the app, the app notices and offers *Download again* or *Remove*, and never crashes or plays nothing.
9. **The app re-checks** at startup, when it returns to the foreground, and when Downloads opens.
10. **Free space is checked for the whole job**, including a copy when finishing needs one, before it starts.

## 5. Design

### 5.1 Engine configuration (`background_file_downloader.dart`)

| Setting | Today | New |
|---|---|---|
| `Config.runInForeground` | not set | **`Config.always`** (Android). The task runs as a foreground service with no time limit, also when UIDT is refused. |
| Manifest | `UIDTJobService` only | Add `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`, and `androidx.work.impl.foreground.SystemForegroundService` with `foregroundServiceType="dataSync"` (CONFIG.md, "run task in foreground"). |
| `transferHints` | `userInitiated`, `largeFile` | Keep `largeFile` (it allows pause). Keep `userInitiated` if D0 shows UIDT works in the foreground, since foreground mode covers the refusals. D1 decides from logcat. |
| Notification | global, title only | **Per task** (`configureNotificationForTask`), so the body can carry the size (§5.9). |
| `retries` | 3 | **10**, the maximum (exponential, 2 s to 512 s). Retries resume from the partial file (parameters.md). See §5.5 for why. |
| `useCacheDir` | `never` | unchanged (multi-GB files) |
| Temp folder | internal `files` | **On the same storage as the destination**, so finishing is a rename, not a copy (§5.6). Spike in D5. |
| `checkAvailableSpace` | 500 MB | Kept, plus our own check before enqueue: total − downloaded + reserve, plus the total again if finishing must copy. |

### 5.2 States and who may change them

Statuses stay `queued`, `running`, `paused`, `failed` and `complete`. Two fields are added (§5.3): **`pausedByUser`** and **`startedOver`**.

| Event | From | To |
|---|---|---|
| User taps Download | none, `failed` | `queued` |
| Engine `enqueued` / `waitingToRetry` | `queued`, `running` | `queued` (keeps the saved bytes) |
| Engine `running`, or **any progress** | `queued`, `running`, `paused` with `pausedByUser = false` | `running` |
| Engine `running`, or progress **past the saved bytes**, while `paused` with `pausedByUser = true` or `failed` | | `running` (resumed from the notification, or rescheduled), except within 3 s of the app's own pause, while the engine stops |
| Engine `queued` while `paused` by the user or `failed` (same 3 s exception) | | `queued` |
| Engine `paused`, and the user asked | any active | `paused`, `pausedByUser = true` |
| Engine `paused`, and the app didn't ask (time limit or the notification's Pause) | `running` | stays `running`; starts the 8 s guard (rule 4) |
| Guard fires with no progress | `running` | ask the engine. Running or queued: stays. Paused: `paused`, `pausedByUser = true`. Unknown: `failed` (`interrupted`) |
| User taps Pause on a task the engine can't pause (holding queue, or between retries) | `queued` | cancel it in the engine, `paused`, `pausedByUser = true`. Resume enqueues it; one that was between retries loses its partial file and says "Started over" |
| Connectivity: no network (§5.5) | `running` | engine pause, `paused`, `pausedByUser = false`, shown as "Waiting for connection". If the engine can't pause it, it stays as it is. `queued` rows are left to the engine: cancelling one waiting to retry would throw its resume data away |
| Connectivity: network back | `paused` with `pausedByUser = false` | Retry with a fresh URL (resume) |
| Engine `complete` | any | `complete` (after the file checks in §5.6) |
| Engine `failed` (final) | any active | `failed` with a reason (§5.5) |
| Engine `canceled`, within 30 s of the app's own cancel (rule 1, holding-queue pause, restart) | | ignored |
| Any other engine `canceled` (the notification's Cancel), when the engine no longer has the task | any active | removed like an in-app cancel (§5.7) |
| User deletes | any | row and files removed (§5.7) |

Engine events, user actions, reconcile and cleanup still run one at a time (`_serial`), as today.

### 5.3 Saved progress (drift schema 4)

New columns on `downloads`:
- `downloadedBytes`: written at most every 2 s while running, and on every pause or failure.
- `pausedByUser`.
- `startedOver`: shown once as "Started over" and cleared by the next progress event.
- `problemDetail`: the engine's own description, for logs and a long-press "Details". Never parsed.
- `updatedAt`: when the row last changed. The 60 s guard and the stale checks use it.
- `contentUri` (Android, nullable): the MediaStore entry of the finished file, if §5.6 needs one.

The live speed and time left stay in memory (`watchProgress`). The bar and the bytes come from the row when there are no live numbers, so they never fall back to 0. **The engine's 0% is no measure** *(2026-11-24)*: each run that isn't a resume (its own retries after a dropped connection) reports 0% before a byte arrives, while the partial file is still there. Once bytes are saved, that 0% is ignored; it had set the row to 0, so an automatic restart thought nothing was lost (found by the live test, §9).

### 5.4 Re-checking the engine (`_reconcile`)

Runs at startup, on `AppLifecycleState.resumed`, and when Downloads opens, through `_serial`, at most once every 5 s.
- It reads every task the engine knows (`database.allRecords()` and `allTasks()`, which includes the holding queue) and fixes each row by the table above.
- **A row the engine doesn't know** is not a failure straight away. The library reschedules killed tasks 5 s after start (`rescheduleKilledTasks`), so the check waits for that first. If it's still unknown, a valid partial file means Retry can continue, and the row becomes `failed` (`interrupted`). Otherwise it's `failed` (`interrupted`) with `startedOver`.
- **A finished row whose file is missing** (§5.8) becomes `missing` in the UI. It isn't a new status: it's `complete` plus a failed file check.
- After the rows, it runs the sweep (§5.7).

### 5.5 Failures and Retry

| Engine says | Reason shown | Automatic action |
|---|---|---|
| `TaskConnectionException` / no HTTP code / socket error | **No connection** | Library retries (10, resuming each time). If connectivity reports no network, we pause instead ("Waiting for connection") and resume when it returns (below) |
| "Task timed out" | **Interrupted** | Shouldn't happen with foreground mode. Retry by itself once |
| HTTP 401/403 | **Link expired** | Fetch a fresh signed URL and resume, once (as today) |
| HTTP 404/410, or the title has no stream | **Not available** | none |
| HTTP 416, or an ETag mismatch on resume | **Started over** | Delete the temp file and enqueue from 0 with a fresh URL |
| HTTP 5xx | **Server error** | Retry with backoff, 3 times |
| `TaskFileSystemException` with "space" | **Storage full** | none. Shows how much is needed |
| Other file errors | **Can't save the file** | none |
| Anything else | **Something went wrong** + Details | none |

**Nothing in the queue waits on the network or the user** *(2026-11-24)*. Engine events and every control go through one queue (`_serial`), so a step that waited there for a fresh URL, a file size, subtitles or a permission dialog held up Pause and Delete of every other download (up to minutes on a weak connection). Now a resume fetches outside the queue (`_resumeNow`) and only applies the result in it, if the row is still what it was for (a Pause or Delete in the meantime wins). Resumes of one download run one after another (`_oneAtATime`), so two at once start it once. Automatic resumes from inside the queue are never awaited there (`_resumeLater`). A new download starts its video first, and its subtitles join the row when they arrive (deleted again if the row is gone). Both permission dialogs are asked before the queue.

**Retry** (`_resumeNow` / `_applyResume`):
1. Fetch a fresh URL (`streams(fresh: true)`). If the stored quality is gone, ask the user before switching quality: it means starting over, and today that happens silently.
2. If the engine still has resume data (`taskCanResume`), `resume` with the new URL.
3. Otherwise cancel the old task, delete its resume data and temp file (rule 1), and enqueue from 0, marked `startedOver`.

**The hard part: a final failure loses the resume data.** The library clears it in `processStatusUpdate` before our listener sees the `failed` (§3.2), so after a final failure there's nothing to continue from. The partial file is still on disk, but nothing refers to it. The plan is therefore to **keep network trouble from becoming a final failure**:
1. `retries: 10`, the library's maximum. Each retry resumes from the partial file, with backoff growing from 2 s to 512 s, which covers about 17 minutes without a connection.
2. **No network means a pause, not a failure.** When connectivity reports no network, the repository pauses its running tasks itself (`pausedByUser = false`, shown as "Waiting for connection · X of Y"). A paused task keeps its resume data indefinitely. When the network returns, it resumes them with a fresh URL; if that URL can't be fetched yet (DNS not ready, API down), the row keeps waiting and asks again 5 s, 10 s, 20 s, 40 s and 80 s later, then waits for the next network change or the user. "No network" is Android's `NET_CAPABILITY_INTERNET`, **not** `VALIDATED`: Google's validation probe fails on networks that reach the Cinemana CDN fine (local ISP routing without international access, VPNs), and a wrong "offline" would pause everything. Changes are debounced 1.5 s on the main thread (`MainActivity.kt`).
3. **Only real failures become final**: storage, not available, link refused twice. Those have no useful partial file anyway, or their partial file is deleted (rule 7).
4. **A final failure no longer loses the partial file** *(2026-11-22)*. The app gives background_downloader its own storage (`PersistentStorage`, public API) wrapped with an in-memory mirror of the resume data. The engine clears that data synchronously just before it sends a final `failed`, so the mirror still has it when the update arrives, and `KeptResumeStore` (`lib/core/downloads/kept_resume_store.dart`, a JSON file in app support) keeps it. Retry gives it back when the partial file is still at least as long as the saved bytes, then resumes with a fresh URL and every retry again. Checked on Linux against the live CDN (`integration_test/downloads_recovery_test.dart`): paused at 11.8%, a final failure cleared the engine's data, and Retry continued from 12.6% and finished at the exact size. Only a missing or short partial file still starts over ("Started over"). iOS keeps URLSession's own resume data, which isn't a path, so it isn't covered.
5. **Passing failures continue by themselves** (network, interrupted, server, link expired), from their partial file: 2, 5, 10, 20, then every 30 minutes while the app runs (up to 12 times, about 5 h; progress resets the count), when the app comes to the front (Android also lets background work run again then, see §12), and when the network returns. At most once a minute each. One that could only start over with bytes saved waits for the user's Retry.
6. **Engine retries get fresh URLs.** A fresh URL has at least 6 hours left, but on a slow connection a 27 GB file takes longer (7.5 h at 1 MB/s), and the engine's own retries, the tasks it reschedules after the app was killed, and the run after a system stop all reuse the URL they started with. Each task carries background_downloader's `Auth` hook with the "token" expiry set 1 hour before the URL's `Expires`. Before every run the native side compares it and, only when it's due, calls `refreshSignedUrl` (a top-level entry point; on Android in a background isolate, so it builds its own `ApiClient`), which fetches the same quality again (`download_url_refresh.dart`). Any problem keeps the old URL, and the 403 handling above is the fallback. A run that has started keeps going past the expiry: the signature is checked when the request arrives. Checked on Linux: a URL due to expire, pointing at an address nothing answers, was replaced and downloaded.
7. **The exception type isn't trusted alone.** On desktop a refused connection arrives as a `TaskFileSystemException` ("ClientException with SocketException …"), which would have read "Couldn't save the file" and never continued, so network errors in the description count as connection errors (`BackgroundFileDownloader.statusFrom`).

D3 tests all of this against the real plugin on Linux (cut the network mid-download) and on the phone (airplane mode, §10).

### 5.6 Where files go, and finishing without a copy

| Platform | Partial file | Finished file | Visible to the user |
|---|---|---|---|
| Android 11+ (API 30+) | Spike (D5): the external app folder `Android/data/<pkg>/files/.partial`, on the same volume as `Movies` | **`/storage/emulated/0/Movies/Cinemakom/<Title>/<file>.mp4`** and its subtitles, written by path (scoped storage allows apps to create media files in `Movies/`). Indexed by MediaStore when the file closes | File managers, video players, gallery |
| Android 10 (API 29) | same | same, with `requestLegacyExternalStorage` | same |
| Android 7–9 (API 24–28) | same | same, after asking for `WRITE_EXTERNAL_STORAGE` (`maxSdkVersion="28"`). If refused, the app folder, as today | same |
| Android TV | same as the phone | `Movies/Cinemakom` | TV file managers |
| Linux / Windows | `<folder>/.partial` (as today) | `~/Videos/Cinemakom` or the chosen folder (as today) | yes, already. Add **Show in folder** on desktop |

**The D5 spike decides how finishing works on Android.** The question is whether the library's `Files.move` from the partial folder to `Movies/` succeeds as a rename on the phone.
- **If it does:** set the partial folder with `useExternalStorage` or the temp path, and finishing is instant.
- **If it doesn't:** finish with a MediaStore copy (`moveToSharedStorage(SharedStorage.video, directory: 'Cinemakom/<Title>')`), which marks the file as pending until it's complete. The space check (rule 10) then counts the copy, and the UI shows "Saving…" while it runs.
- `UriDownloadTask` (writing straight into MediaStore) is **not** an option: Android can't resume URI downloads (`prepareInterruptedResume` requires a temp file), and resume is the whole point.

**Names:** `<Title> (<Year>)/<Title> S01E02 1080p.mp4` and subtitles `….ar.srt` / `….en.srt` beside it, so players pick them up. If a file with that name already exists and isn't ours, add ` (2)` and so on. **Names other rows hold count too** *(2026-11-24)*: a download's file only appears when it finishes, so two at once with one name (a dubbed and a subtitled release of one series, both `Friends`) got one path, and one overwrote the other and deleting either deleted both. `uniqueFileStem` takes every other row's path (`taken`, compared without case).

**Existing downloads** (from Phase 6, in `Android/data/<pkg>/files/Downloads`): on the first start after the update, move the finished ones to `Movies/Cinemakom` (a rename on the same volume). The row keeps whichever path worked, so nothing breaks if the move fails. Unfinished ones are restarted (they're broken anyway, §3).

**Uninstall:** files in `Movies/Cinemakom` stay. That's intended, the owner wants the files to belong to the user. After a reinstall the old files aren't in the new database and aren't owned by the new install. The app ignores them (no media permission requested). Re-downloading the same title writes `… (2).mp4`.

### 5.7 Cleanup (`DownloadsJanitor`, a small class beside the repository)

Runs after each reconcile, after delete, cancel and final failures, and after a quality change.
1. **Temp files.** List `com.bbflight.background_downloader*` in every folder the engine uses: internal `files`, external `files` and its `.partial`, desktop `.partial`. Since the library doesn't say which temp file is whose, we match by count and age: every **running or queued** row has a slot (a queued one may be waiting to retry from its partial file, up to 512 s between tries, or be the holding queue's next task, started natively before Dart hears of it), and so does a paused or failed row the engine can still resume. The newest files fill the slots, and any file written in the last 2 minutes stays while a row is running or queued. A partial file the engine's resume data (or the kept data, §5.5) names is kept **exactly**, and its row needs no slot; kept data of a download that's gone is forgotten. **Everything else is deleted.** A restart sweeps with its own row excluded, so its old file goes at once. If there are no unfinished tasks at all, every temp file goes. *(Changed 2026-11-22: queued rows had no slot, so a sweep deleted the partial file of a download waiting to retry; PR #4 review, critical 2.)*
2. **A failed download's leftover video**, at that download's own path (an interrupted copy), is deleted, **only when it's known to be cut short**: its size is known and the file isn't that size *(2026-11-24)*. One of unknown size may be the whole film, finished while the app wasn't listening (the re-check can only complete a file of known size, §3.4), so it stays; the automatic continue, with its fresh URL, asks the CDN for the size and completes a whole file without downloading it again, or learns the size of a cut copy. In the app-private Phase 6 folder (`Android/data/<pkg>/files/Downloads`), which the user can't manage, a video or subtitle no row claims goes too. **Nothing else in a download folder is:** the folders are the user's (`Movies/Cinemakom`, `~/Videos/Cinemakom`), so a video no row claims (renamed, from an earlier install or before the app's data was cleared, put there by hand) and a finished download's video, whatever its size, always stay. *(Changed 2026-11-22: the first version deleted every unclaimed video and any size mismatch, which would have deleted renamed files and every earlier download; PR #4 review, critical 1.)*
3. **Subtitles** of a failed download whose video is gone are deleted; a finished download's subtitles stay even if its video was renamed, and a subtitle no row lists is never touched. Then the failed download's own folder, if that left it empty. *(2026-11-24: a download folder the user can see is never listed or swept as a whole, since on desktop it can be `~/Videos` or the home folder; only the failed rows' exact paths are touched. An empty folder no row owns is the user's. The app-private Phase 6 folder is still swept whole.)*
4. Each run logs what it removed and how many bytes (`debugPrint`), so a phone check can see it in logcat.

**Downloads screen storage line:** "Downloads use 27 GB · 120 GB free", counting the partial files too.

On the owner's phone, the first start of the fixed build removes the 11.5 GB of strays.

### 5.8 Changes made outside the app

The user may delete, move or rename a finished file in their file manager (rule 8).
- **Checked:** at startup, on app resume, when Downloads opens, and before playing (`playable()` already checks).
- **A missing video** shows "File removed" with **Download again** (same quality, same place) and **Remove**. It never shows as playable offline.
- **Missing subtitles** are fetched again in the background on the next check, if online.
- **Deleting in the app** deletes the user's file from `Movies/Cinemakom`. The confirm dialog says so: "Delete the file from your phone too".

### 5.9 The notification (Android)

Configured **per task** (`configureNotificationForTask`), so the total size and quality are part of the text. It's in the app's language (the `DownloadNotices` texts, from the ARB files, as today).

| State | Title | Body | Buttons | Tap |
|---|---|---|---|---|
| Downloading | `The Odyssey` / `Friends · S01E02` | `4K · 27 GB · {progress} · {networkSpeed} · {timeRemaining} left` | Pause, Cancel | opens Downloads |
| Waiting (holding queue) | title | `Waiting for a slot · 4K · 27 GB` | Cancel | opens Downloads |
| Paused by the user | title | `Paused · {progress}` | Resume, Cancel | opens Downloads |
| Failed | title | the reason (§5.5), e.g. `Storage full: 12 GB more needed` | none | opens Downloads at that row |
| Finished | title | `Downloaded · 27 GB · Movies/Cinemakom` | none | opens Downloads (offline play is one tap from there) |

- The library can't show the downloaded bytes ("3.6 of 27 GB"), only `{progress}` in percent, so the body pairs the percent with the total.
- The failed text is fixed when the task is queued, and the library has no placeholder for the reason, so the notification says "Download failed" and the app shows the reason.
- The holding queue has no notification in the library, so "Waiting for a slot" isn't shown (the string was removed).
- Per-task texts live in the library's memory only: `resume` sets them again (after a restart they'd fall back to the global ones).
- Pause and Resume buttons come from the `paused` configuration (notifications.md). Their labels follow the system language on Android. D6 checks whether they can be localized and documents it if not.
- With foreground mode the notification stays up for the whole download (one per task). The time-limit `paused` (§3.1) no longer happens.
- Tap handling: `FileDownloader().registerCallbacks(taskNotificationTapCallback: …)` opens the Downloads tab through go_router.
- Desktop has no notification (as today).

### 5.10 The Downloads screens (phone and TV)

- Each row shows its state with the saved bytes: "Downloading · 3.6 of 27 GB · 9.8 MB/s · 26 min left", "Paused · 3.6 of 27 GB", "Waiting for connection · 3.6 of 27 GB", "Stopped: storage full · 3.6 of 27 GB", "File removed".
- The bar shows the saved fraction in every state (dimmed when not running).
- A long press (phone) or the menu (TV) gives **Details**: the reason, the engine's description, the file path, and **Show in folder** on desktop.
- Pause works on waiting items too (§5.2).
- The storage line from §5.7.
- TV: the same states through `tv_downloads_screen.dart` / `tv_downloads.dart`, labels from the shared layout-free files (AGENTS.md TV rules).
- Every new string goes in both ARB files. Mixed captions use `context.joinMeta`.

## 6. Code map (after the change)

```
lib/core/downloads/
  downloader.dart                  # interface: adds lifecycle re-check hooks, tempFiles(), canResume(id)
  background_file_downloader.dart  # the only file importing background_downloader: config §5.1, per-task notifications, tap callback
lib/data/repositories/
  downloads_repository.dart        # state rules §5.2, retry §5.5, reconcile §5.4
  downloads_janitor.dart           # cleanup §5.7 (pure file logic, unit-tested on a temp folder)
  download_store.dart              # schema 4 columns §5.3
  download_paths.dart              # where files go per platform §5.6, names, migration of old downloads
lib/features/downloads/            # rows with saved bytes, Details, storage line
lib/tv/...                         # same states on TV
android/app/src/main/AndroidManifest.xml  # foreground service, permissions (§5.1, §5.6)
ios/Runner/Info.plist              # Files app keys (§5.6)
```

## 7. Logging

Every state change, engine event and cleanup action is logged in one line through `debugPrint`, tagged `[downloads]`: task ID, from → to, reason, bytes. Release builds keep these lines (`debugPrint` prints in release), so `adb logcat | grep '\[downloads\]'` on the owner's phone shows what happened. No telemetry is sent anywhere (AGENTS.md Don'ts).

## 8. Milestones

Each milestone ends with `fvm flutter analyze` clean, `fvm flutter test` green, and its own tests. Phone steps need the phone on USB.

| | What | Done when |
|---|---|---|
| **D0** | **Confirm the causes.** Logcat during a background download of a big file on the phone. Look for `timed out`, `paused due to timeout`, `could not re-enqueue` and UIDT fallback lines. Check the CDN size of The Odyssey (§3.6). | The logcat lines match §3.1, or the plan is corrected here |
| **D1** | **No time limits.** Foreground mode, manifest, retries, hints. | Logcat shows no timeouts during a 30-minute download with the app in the background and the screen off |
| **D2** | **States and saved progress.** Schema 4, the §5.2 rules, the 60 s guard, re-check on resume, holding-queue pause, failure reasons, the Downloads rows. | The §9 state tests pass. "1 MB of 27 GB" can't happen |
| **D3** | **Retry that continues.** Rule 1, `retries: 10`, pause on no network and resume on return (§5.5), whether resume data can survive a final failure, started-over handling, the quality-change prompt. | A download failed by cutting the network, then retried, continues from its bytes (Linux integration test and the phone) |
| **D4** | **Cleanup.** The janitor, the storage line, logs. | After forced failures, retries and deletes, only finished files remain (unit test on a temp folder, Linux integration test). The owner's phone gets its 11.5 GB back |
| **D5** | **Files in Movies/Cinemakom.** The rename spike first (debug APK on the phone, a 50 MB file), then paths per API level, the move of existing downloads, the outside-change handling, Show in folder. | A finished download is in `Movies/Cinemakom` in the phone's file manager and plays in another video app. Deleting it in the file manager shows "File removed" in the app |
| **D6** | **The notification** (§5.9). | Checked on the phone in English and Arabic: every state from the table, the buttons work, a tap opens Downloads |
| **D7** | **Proof.** The full phone checklist (§10) on a release APK, the TV check (TCL), Windows if available. Docs: tick this plan, PLAN.md Phase 6, API.md if anything about ranges or sizes changed. | The owner signs off on the phone |

Order: D0 → D1 → D2 → D3 → D4 → D5 → D6 → D7. D2 to D4 don't need the phone and can start while waiting for it. D1 and D5 can't be finished without it.

## 9. Tests

**Unit (`test/data/downloads_repository_test.dart`, with `test/helpers/fake_downloader.dart` taught the new events):**
- Time-limit `paused` with no user pause, then progress: the row stays `running`, and the bar never resets.
- Progress after a user pause: ignored. After Resume: `running`.
- `paused` late, after `running` of the next run (the race in §3.2): stays `running`.
- No progress for 60 s after a time-limit pause: `failed` (`interrupted`).
- Pause while in the holding queue: `paused`, and Resume enqueues it.
- Each row of §5.5's table maps to its reason and action.
- Retry with resume data: `resume` with the fresh URL. Without it: old task cancelled, temp deleted, enqueue from 0, `startedOver`.
- Quality gone on Retry: asks, doesn't switch silently.
- Reconcile: an unknown task waits for the reschedule, then becomes `interrupted`. A `complete` engine task with a missing file shows "File removed".
- Saved bytes survive pause, failure, restart (a new repository on the same store) and reconcile.
- No network: running tasks pause as "Waiting for connection", resume by themselves when it's back, and a user pause stays paused.
- Rule 1: never two tasks or two temp files for one download.

**Janitor (`test/data/downloads_janitor_test.dart`, on a real temp folder):** keeps running and resumable temp files, deletes the rest; keeps every video and subtitle the user owns (renamed, unclaimed, a size mismatch, a folder with no rows at all) and deletes only a failed download's leftover, its subtitles and the folder that left empty (never another empty folder: the user's); reports the bytes.

**Paths (`test/data/download_paths_test.dart`):** names per platform and API level, ` (2)` for clashes, migration of Phase 6 rows.

**Widget:** Downloads rows in every state, in English and Arabic (saved bytes, reasons, "File removed", the storage line). The TV Downloads screen gets the same, plus `expectNoTraps`.

**Integration on Linux (`integration_test/downloads_test.dart`, live CDN, extended):** pause and resume (as today); a failure mid-download, then Retry continues from the same bytes; delete during a download leaves no `.partial` files; a finished file deleted by hand shows "File removed"; *(2026-11-24)* two downloads with one name at once get two files, and deleting one keeps the other; the connection dying under the engine keeps the saved bytes through its retries, and Pause then Retry finishes.

**The queue (unit, 2026-11-24):** a Resume, a new download's subtitles, a quality switch's size, a re-download and the permission dialog each hang while another download's Pause goes through at once; two Resumes at once start one; a Pause during an automatic retry's fetch wins; subtitles that arrive after a delete go with their folder.

**Recovery on Linux (`integration_test/downloads_recovery_test.dart`, live CDN):** a final failure, then Retry continues from the saved bytes; a URL about to expire is replaced before the run starts. Needs `WAYLAND_DISPLAY`/`DISPLAY` set in a shell without them.

## 10. Phone checklist (release APK, OnePlus, Android 15)

Logcat runs during all of it (`adb logcat | grep -E '\[downloads\]|BackgroundDownloader|TaskRunner'`).

1. Start a 4K movie, leave the app at once, screen off for 30 minutes. It never shows "Paused". The notification stays and updates, and logcat shows no timeouts.
2. Pause and Resume from the notification and from the app: the bytes continue.
3. Airplane mode for 2 minutes mid-download: "Waiting for connection · X of Y". Network back: it continues by itself from X. Then a slow or flaky network (a weak signal, or throttled in developer options) for 30 minutes: it never starts over, and continues by itself.
4. Force-stop mid-download, reopen: it continues, or shows "Interrupted · X of Y" and Retry continues from X.
5. Delete a running, a paused and a failed download. Settings → Apps → Cinemakom → Storage drops by the matching amount every time.
6. A finished download is in `Movies/Cinemakom` in the file manager, plays in another player with its subtitles, and plays offline in the app with subtitles.
7. Delete it in the file manager: the app shows "File removed". Download again works.
8. Download season (5 episodes): 2 at a time, the rest waiting, all finish with the app in the background.
9. Fill the storage until less than the file is free: "Storage full: N GB more needed", and nothing is left behind.
10. The notification in Arabic, every state.
11. The first start after updating from the Phase 6 build: the 11.5 GB of strays are removed, and finished downloads moved to `Movies/Cinemakom` still play.
12. TV (TCL): one movie download with the app in the background, then offline play.
13. One download longer than 6 hours with the app in the background (Android 15's limit, §12), or a 4K title on a throttled network: it finishes, or stops and continues from its bytes when the app is opened.

## 11. Libraries considered *(2026-11-21)*

| Option | Verdict |
|---|---|
| **background_downloader** (current) | **Keep.** Maintained (9.6.x in 2026, issues in the 700s fixed), every platform we ship, headers, pause and resume with a new URL, native holding queue, foreground mode, notifications, shared storage. Its sharp edges are documented, and this plan handles them. |
| flutter_downloader | Older, Android and iOS only (no Linux or Windows), weaker pause and resume, slower maintenance. A step back. |
| Android's system DownloadManager (through a plugin or platform code) | Very robust on Android and writes to public folders. But it has no pause, can't resume with a new signed URL, its notification can't be changed, and it's Android only, so we'd keep a second engine for desktop and iOS. Not worth two engines. |
| Writing our own engine | No: that's the "reinvent the wheel" the owner wants to avoid. |

If D0–D3 show a bug inside the library itself (not in our setup), report it upstream with a small reproduction and work around it in `background_file_downloader.dart`. Don't fork.

## 12. Risks and open questions

- **The rename into `Movies/` may be refused** on some Android versions or OEM builds (D5 spike). The fallback is the MediaStore copy, with its space and time cost shown.
- **`useExternalStorage` can't be switched back** once used (CONFIG.md). Decide in the D5 spike and never toggle it later. Our downloads use absolute paths (`root`), so existing rows aren't affected.
- **OEM battery savers** (ColorOS) may still kill a foreground service. D1 checks on the OnePlus. If it happens, the reconcile and auto-retry rules (§5.4, §5.5) bring the download back, and Settings may need a hint to turn off battery optimisation for the app.
- **Temp-file matching is by count and age** (§5.7), because the library doesn't say which file is whose. A wrong guess would delete a paused task's partial file, so that task starts over. That costs time but never leaves junk. D4 checks whether the resume data path can be read safely instead.
- **Very large files (27 GB)** strain storage on phones and TVs. The space check is up front, and the quality picker already shows sizes.
- **Android 15 limits `dataSync` foreground services to 6 hours a day** (the app targets SDK 36, so it applies). A download longer than that (27 GB below ~1.3 MB/s, normal on a slow connection) is stopped by the system when WorkManager runs it; a UIDT job (used when Android allows it, `TransferHint.userInitiated`) has no such limit. A stopped run counts as a failure and is retried from its partial file; if Android won't start the service again, the retries run out and the failure is final. Since 2026-11-22 that no longer costs anything: the resume data is kept (§5.5 point 4), and the download continues as soon as the app comes to the front (Android resets the quota then) or on the next slow retry. Not yet seen on the phone: D7 should include one download of more than 6 hours with the app in the background.
- **Signed URLs expire during long downloads**: handled by the `Auth` refresh (§5.5 point 6). It's marked experimental in background_downloader; if a library update changes it, the 403 handling and kept resume data still continue the download.
- **`Download.contentUri`** (schema 4) is unused: the D5 rename into `Movies/Cinemakom` worked on Android 15, so no MediaStore copy is needed. It's kept for that fallback, should an OEM refuse the rename.
