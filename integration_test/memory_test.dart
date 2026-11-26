// The app's memory over a session (docs/MEMORY.md §4): profile mode, live
// API, the real engine (mpv on desktop, ExoPlayer on Android), the phone or
// TV UI as the device has it. Three scenarios:
//
//   cycle   open a 4K video, play PLAY_SECONDS, close, wait 30 s; CYCLES
//           times. Does closing give memory back (T1), and do ten videos
//           use more than one (T2)?
//   browse  Home three times, 3 genre pages scrolled far, 10 titles, then
//           IDLE_MINUTES idle. Does browsing level off (T3)?
//   long    LONG_MINUTES of 4K with seeks and a quality switch (T4).
//   download  a 1080p download (into build/memory on desktop, an in-memory
//           database), sampled for DOWNLOAD_MINUTES (it finishes in a few
//           on a fast connection, and the rest shows what it keeps), then
//           deleted (§3.5).
//
// Every run also lists the Dart classes whose instances grew most from
// start to end (`classes` in the report).
//
// On Linux every sample also has glibc's own count of the memory it has
// handed out and the freed memory it keeps for reuse (`mallinfo2`), and
// MEMORY_TRIM=true adds a "trimmed" sample after each close: the same,
// after `malloc_trim(0)` gave the kept memory back (§4.4). On Android it's
// after Java's garbage was collected (MainActivity's `collectGarbage`).
//
//   fvm flutter drive --profile -d linux \
//     --driver=test_driver/memory_driver.dart \
//     --target=integration_test/memory_test.dart \
//     --dart-define=MEMORY_SCENARIO=cycle
//
// On a phone or TV add --no-dds and -d <device-id>. `flutter drive`
// reinstalls the app there, which wipes its data. The driver writes
// build/memory/<device>-<ui>-<scenario>.json and prints the table
// (tool/memory_report.dart).
//
// Without the driver (the built app run by itself, say on another machine
// over SSH) it still runs, and prints the report as one `MEMORY_JSON` line:
// save it as a .json file for tool/memory_report.dart.
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:cinemakom/app/app.dart';
import 'package:cinemakom/app/catalog_providers.dart';
import 'package:cinemakom/app/router.dart';
import 'package:cinemakom/app/widgets/poster_card.dart';
import 'package:cinemakom/core/diagnostics/event_log.dart';
import 'package:cinemakom/core/diagnostics/memory.dart';
import 'package:cinemakom/core/network/api_endpoints.dart';
import 'package:cinemakom/core/platform/app_info.dart';
import 'package:cinemakom/core/platform/platform_info.dart';
import 'package:cinemakom/core/player/media_kit_engine.dart';
import 'package:cinemakom/core/storage/database.dart';
import 'package:cinemakom/core/storage/preferences.dart';
import 'package:cinemakom/data/models/localized_text.dart';
import 'package:cinemakom/data/models/media_item.dart';
import 'package:cinemakom/data/models/playback_request.dart';
import 'package:cinemakom/data/repositories/downloads_repository.dart';
import 'package:cinemakom/data/repositories/library_repository.dart';
import 'package:cinemakom/features/player/player_controller.dart';
import 'package:cinemakom/features/player/player_state.dart';
import 'package:cinemakom/main.dart' show noRetry;
import 'package:cinemakom/tv/tv_app.dart';
import 'package:cinemakom/tv/tv_router.dart';
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vm_service/vm_service.dart' as vm;
import 'package:vm_service/vm_service_io.dart';

const scenario = String.fromEnvironment(
  'MEMORY_SCENARIO',
  defaultValue: 'cycle',
);
const cycles = int.fromEnvironment('CYCLES', defaultValue: 10);
const playSeconds = int.fromEnvironment('PLAY_SECONDS', defaultValue: 60);
const longMinutes = int.fromEnvironment('LONG_MINUTES', defaultValue: 20);
const idleMinutes = int.fromEnvironment('IDLE_MINUTES', defaultValue: 10);
const quality = int.fromEnvironment('MEMORY_QUALITY', defaultValue: 2160);
const trim = bool.fromEnvironment('MEMORY_TRIM');
const downloadMinutes = int.fromEnvironment(
  'DOWNLOAD_MINUTES',
  defaultValue: 10,
);

/// How long after closing the player a "closed" sample waits (T1).
const afterClose = Duration(seconds: 30);

/// Avengers: Endgame: 4K, as in the perf tests.
const request = PlaybackRequest(
  item: MediaItem(
    id: '301561',
    title: LocalizedText(en: 'Avengers: Endgame'),
    kind: VideoKind.movies,
  ),
  start: Duration(minutes: 20),
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  // As the app starts it: an AppImage-style bundle uses its own libmpv.
  initMediaKit();

  Future<void> wait(Duration d) => binding.delayed(d);

  testWidgets('memory: $scenario', timeout: const Timeout(Duration(hours: 3)), (
    tester,
  ) async {
    final tv = useTvUi;
    if (tv && !isAndroid) {
      // A desktop dry run of the TV UI gets the TV's 960 × 540 dp canvas.
      tester.view
        ..physicalSize = const Size(1920, 1080)
        ..devicePixelRatio = 2;
      addTearDown(tester.view.reset);
    }
    final heap = await _DartHeap.connect();
    // Desktop: under build/, not the temp folder (RAM on many Linuxes).
    // Absolute: the downloader reads a relative folder from `/`.
    final downloadDir = isDesktop
        ? (Directory('build/memory/download').absolute
            ..createSync(recursive: true))
        : Directory.systemTemp.createTempSync('cinemakom-memory');
    final downloadDb = AppDatabase(NativeDatabase.memory());
    addTearDown(() async {
      await downloadDb.close();
      if (downloadDir.existsSync()) downloadDir.deleteSync(recursive: true);
    });
    final clock = Stopwatch()..start();
    final samples = <Map<String, Object?>>[];

    /// One sample. [gc] collects Dart's garbage first, so the heap shows
    /// what is really kept.
    Future<void> sample(String label, {bool gc = false}) async {
      // The process first: asking the VM for its allocation profile (the
      // forced GC) costs it 30–40 MB for a moment.
      final memory = await readMemory();
      final glibc = _Glibc.instance?.read();
      final dart = await heap?.read(gc: gc);
      final row = {
        'label': label,
        't_s': clock.elapsed.inSeconds,
        ...memory.toJson(),
        ...?dart,
        ...?glibc,
        if (!isAndroid) 'players': MediaKitEngine.livePlayers,
      };
      samples.add(row);
      debugPrint('memory ${row['t_s']}s $label: ${memory.describe()}');
    }

    /// With MEMORY_TRIM, after a "closed" sample: glibc gives back the
    /// freed memory it keeps (Linux), or Java collects its garbage
    /// (Android), and a "trimmed" sample shows what's left.
    Future<void> trimmed(String label) async {
      if (!trim) return;
      if (isAndroid) {
        // Android: Java's garbage collected, then time for the runtime to
        // hand freed pages back.
        await collectJavaGarbage();
        await wait(const Duration(seconds: 5));
      } else {
        final glibc = _Glibc.instance;
        if (glibc == null) return;
        glibc.trim();
        await wait(const Duration(seconds: 2));
      }
      await sample(label);
    }

    await tester.pumpWidget(
      ProviderScope(
        retry: noRetry,
        overrides: [
          preferenceStoreProvider.overrideWith(
            (ref) => MemoryPreferenceStore({
              PreferenceKeys.language: 'en',
              PreferenceKeys.defaultQuality: quality,
            }),
          ),
          libraryRepositoryProvider.overrideWithValue(
            MemoryLibraryRepository(),
          ),
          // The download scenario keeps away from the real downloads.
          if (scenario == 'download') ...[
            appDatabaseProvider.overrideWithValue(downloadDb),
            downloadRootProvider.overrideWithValue(
              () async => (baseDirectory: 'root', directory: downloadDir.path),
            ),
          ],
        ],
        child: tv ? const TvApp() : const CinemakomApp(),
      ),
    );
    // Home's first rows and their artwork.
    await wait(const Duration(seconds: 10));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(tv ? TvApp : CinemakomApp)),
    );
    final GoRouter router = container.read(
      tv ? tvRouterProvider : routerProvider,
    );
    await sample('start', gc: true);
    final classesAtStart = await heap?.classes();

    PlayerState player() => container.read(playerControllerProvider(request));
    Future<void> openPlayer() async {
      router.push('${AppRoutes.watch}/${request.videoId}', extra: request);
      final end = DateTime.now().add(const Duration(seconds: 60));
      while (!(player().phase == PlayerPhase.ready && player().playing)) {
        if (DateTime.now().isAfter(end)) fail('the video never played');
        await wait(const Duration(milliseconds: 200));
      }
    }

    final keys = _Keys(wait);

    switch (scenario) {
      case 'cycle':
        for (var i = 1; i <= cycles; i++) {
          await openPlayer();
          await wait(const Duration(seconds: playSeconds));
          await sample('playing #$i (${player().quality?.label})');
          router.pop();
          await wait(afterClose);
          await sample('closed #$i', gc: true);
          await trimmed('trimmed #$i');
        }
      case 'browse':
        final genres = (await container.read(genresProvider.future))
            .take(3)
            .toList();
        for (var pass = 1; pass <= 3; pass++) {
          tv ? await keys.browseTvHome() : await _scrollAll(tester, wait);
          await sample('home pass $pass');
        }
        var titles = 0;
        for (final genre in genres) {
          router.push('${AppRoutes.home}/genre/${genre.id}', extra: genre);
          await wait(const Duration(seconds: 4));
          // About 10 pages of 30 titles, loading as it goes.
          tv
              ? await keys.hold(LogicalKeyboardKey.arrowDown, repeats: 120)
              : await _scrollAll(tester, wait, steps: 40, back: false);
          await sample('genre ${genre.id} scrolled');
          for (var i = 0; i < (genres.last == genre ? 4 : 3); i++) {
            tv ? await keys.press(keys.ok) : await _openPoster(tester, i);
            await wait(const Duration(seconds: 4));
            tv ? await keys.press(LogicalKeyboardKey.escape) : router.pop();
            await wait(const Duration(seconds: 1));
            titles++;
            if (tv) await keys.press(LogicalKeyboardKey.arrowRight);
          }
          router.pop();
          await wait(const Duration(seconds: 2));
        }
        await sample('after $titles titles', gc: true);
        for (var half = 1; half <= idleMinutes * 2; half++) {
          await wait(const Duration(seconds: 30));
          await sample('idle ${half * 30} s', gc: half == idleMinutes * 2);
        }
        await trimmed('trimmed');
      case 'long':
        await openPlayer();
        final controller = container.read(
          playerControllerProvider(request).notifier,
        );
        for (var half = 1; half <= longMinutes * 2; half++) {
          await wait(const Duration(seconds: 30));
          final minute = half / 2;
          // None in the last 5 minutes, which T4 measures.
          if (minute == 5 || minute == 10 || minute == 14) {
            await controller.seekBy(const Duration(minutes: 5));
          }
          if (minute == 8) {
            // Down one quality and straight back up.
            final sources = player().sources;
            final now = player().quality;
            final lower = sources.where((s) => s != now).firstOrNull;
            if (lower != null && now != null) {
              await controller.selectQuality(lower);
              await wait(const Duration(seconds: 20));
              await controller.selectQuality(now);
            }
          }
          await sample('playing ${half * 30} s (${player().quality?.label})');
        }
        router.pop();
        await wait(afterClose);
        await sample('closed', gc: true);
        await trimmed('trimmed');
      case 'download':
        final repo = container.read(downloadsRepositoryProvider);
        // The downloads' own log lines, which the test's run would lose.
        final logged = EventLog.instance.changes.listen((_) {
          final e = EventLog.instance.recent.lastOrNull;
          if (e != null && (e.tag == 'downloads' || e.tag == 'error')) {
            debugPrint('log ${e.format()}');
          }
        });
        addTearDown(logged.cancel);
        final choices = (await tester.runAsync(
          () => repo.choices(request.videoId),
        ))!;
        final choice =
            choices.where((c) => c.source.height == 1080).firstOrNull ??
            choices.last;
        debugPrint(
          'memory: downloading ${choice.source.label}, '
          '${((choice.bytes ?? 0) / (1 << 20)).round()} MB',
        );
        await tester.runAsync(
          () => repo.download(
            request.item,
            source: choice.source,
            bytes: choice.bytes,
          ),
        );
        for (var half = 1; half <= downloadMinutes * 2; half++) {
          await wait(const Duration(seconds: 30));
          final row = await tester.runAsync(() => repo.get(request.videoId));
          final mb = ((row?.downloadedBytes ?? 0) / (1 << 20)).round();
          await sample(
            'downloading ${half * 30} s ($mb MB, ${row?.status.name})',
          );
        }
        await tester.runAsync(() => repo.delete(request.videoId));
        await wait(afterClose);
        await sample('deleted', gc: true);
      default:
        fail(
          'unknown MEMORY_SCENARIO "$scenario" '
          '(cycle, browse, long, download)',
        );
    }

    final classesAtEnd = await heap?.classes();
    final info = await readAppInfo();
    binding.reportData = {
      'memory': {
        'scenario': scenario,
        'device': info.device,
        'ui': tv ? 'tv' : (isDesktop ? 'desktop' : 'phone'),
        'version': info.version,
        'quality': quality,
        'samples': samples,
        if (classesAtStart != null && classesAtEnd != null)
          'classes': _grown(classesAtStart, classesAtEnd),
      },
    };
    // For a run without `flutter drive` (another machine over SSH): the
    // report as one line, for tool/memory_report.dart.
    stdout.writeln('MEMORY_JSON ${jsonEncode(binding.reportData!['memory'])}');
    heap?.dispose();
  });
}

/// The vertical list on screen (Home's, a genre grid's).
Finder get _vertical => find
    .byWidgetPredicate(
      (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
    )
    .first;

/// Down the page in [steps] drags, letting pages and artwork load, then
/// back to the top unless [back] is false.
Future<void> _scrollAll(
  WidgetTester tester,
  Future<void> Function(Duration) wait, {
  int steps = 15,
  bool back = true,
}) async {
  for (var i = 0; i < steps; i++) {
    await tester.drag(_vertical, const Offset(0, -600));
    await wait(const Duration(milliseconds: 700));
  }
  if (!back) return;
  for (var i = 0; i < steps; i++) {
    await tester.drag(_vertical, const Offset(0, 600));
    await wait(const Duration(milliseconds: 300));
  }
}

/// Opens the [i]th poster on screen.
Future<void> _openPoster(WidgetTester tester, int i) async {
  final posters = find.byType(PosterCard).hitTestable();
  final count = posters.evaluate().length;
  if (count == 0) fail('no poster on screen to open');
  await tester.tap(posters.at(i % count));
}

/// The remote, for the TV UI (as in tv_perf_test.dart).
class _Keys {
  _Keys(this.wait);

  final Future<void> Function(Duration) wait;

  /// OK: Select on the TV, Enter on a desktop dry run.
  LogicalKeyboardKey get ok =>
      isAndroid ? LogicalKeyboardKey.select : LogicalKeyboardKey.enter;

  /// Profile builds drop the keys' debug names, which
  /// `simulateKeyDownEvent` needs to find the physical key itself.
  static PhysicalKeyboardKey _physical(LogicalKeyboardKey key) => switch (key) {
    LogicalKeyboardKey.arrowUp => PhysicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown => PhysicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft => PhysicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight => PhysicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.select => PhysicalKeyboardKey.select,
    LogicalKeyboardKey.enter => PhysicalKeyboardKey.enter,
    LogicalKeyboardKey.escape => PhysicalKeyboardKey.escape,
    _ => throw ArgumentError('No physical key for $key'),
  };

  Future<void> press(LogicalKeyboardKey key, {int times = 1}) async {
    for (var i = 0; i < times; i++) {
      await simulateKeyDownEvent(key, physicalKey: _physical(key));
      await simulateKeyUpEvent(key, physicalKey: _physical(key));
      await wait(const Duration(milliseconds: 350));
    }
  }

  /// A held arrow: the key repeats every 50 ms, as on a remote.
  Future<void> hold(LogicalKeyboardKey key, {int repeats = 40}) async {
    await simulateKeyDownEvent(key, physicalKey: _physical(key));
    await wait(const Duration(milliseconds: 400));
    for (var i = 0; i < repeats; i++) {
      await simulateKeyRepeatEvent(key, physicalKey: _physical(key));
      await wait(const Duration(milliseconds: 50));
    }
    await simulateKeyUpEvent(key, physicalKey: _physical(key));
    await wait(const Duration(milliseconds: 600));
  }

  /// Down through Home, along every third row, and back up.
  Future<void> browseTvHome() async {
    for (var row = 0; row < 12; row++) {
      await press(LogicalKeyboardKey.arrowDown);
      if (row % 3 == 1) {
        await hold(LogicalKeyboardKey.arrowRight);
        await hold(LogicalKeyboardKey.arrowLeft);
      }
    }
    await press(LogicalKeyboardKey.arrowUp, times: 14);
  }
}

/// The Dart heap, through the app's own VM service (profile and debug
/// builds). `null` where there is none.
class _DartHeap {
  _DartHeap(this._service, this._isolate);

  final vm.VmService _service;
  final String _isolate;

  static Future<_DartHeap?> connect() async {
    try {
      final info = await developer.Service.getInfo();
      final uri = info.serverWebSocketUri;
      final id = developer.Service.getIsolateId(Isolate.current);
      if (uri == null || id == null) return null;
      return _DartHeap(await vmServiceConnectUri(uri.toString()), id);
    } on Object catch (e) {
      debugPrint('memory: no VM service ($e), so no Dart heap numbers');
      return null;
    }
  }

  /// Used and reserved heap, and the native memory Dart objects hold
  /// (images, buffers), in MB. [gc] collects garbage first.
  Future<Map<String, Object?>> read({bool gc = false}) async {
    try {
      if (gc) await _service.getAllocationProfile(_isolate, gc: true);
      final usage = await _service.getMemoryUsage(_isolate);
      int mb(int? bytes) => ((bytes ?? 0) / (1 << 20)).round();
      return {
        'heap_mb': mb(usage.heapUsage),
        'heap_capacity_mb': mb(usage.heapCapacity),
        'external_mb': mb(usage.externalUsage),
      };
    } on Object {
      return const {};
    }
  }

  /// Every Dart class with live instances, after a GC: by name (library
  /// and class), its instance count and bytes.
  Future<Map<String, ({int count, int bytes})>?> classes() async {
    try {
      final profile = await _service.getAllocationProfile(_isolate, gc: true);
      final out = <String, ({int count, int bytes})>{};
      for (final m in profile.members ?? const <vm.ClassHeapStats>[]) {
        final name = m.classRef?.name;
        if (name == null || (m.instancesCurrent ?? 0) == 0) continue;
        final lib = m.classRef?.library?.uri ?? '';
        final key = lib.isEmpty ? name : '$name ($lib)';
        final was = out[key];
        out[key] = (
          count: (was?.count ?? 0) + (m.instancesCurrent ?? 0),
          bytes: (was?.bytes ?? 0) + (m.bytesCurrent ?? 0),
        );
      }
      return out;
    } on Object {
      return null;
    }
  }

  void dispose() => _service.dispose();
}

/// The [top] classes that grew most in bytes from [start] to [end].
List<Map<String, Object>> _grown(
  Map<String, ({int count, int bytes})> start,
  Map<String, ({int count, int bytes})> end, {
  int top = 20,
}) {
  final rows = [
    for (final MapEntry(:key, :value) in end.entries)
      (
        name: key,
        count: value.count - (start[key]?.count ?? 0),
        bytes: value.bytes - (start[key]?.bytes ?? 0),
        countEnd: value.count,
      ),
  ]..sort((a, b) => b.bytes.compareTo(a.bytes));
  return [
    for (final r in rows.take(top))
      {
        'class': r.name,
        'instances_grown': r.count,
        'instances': r.countEnd,
        'kb_grown': (r.bytes / 1024).round(),
      },
  ];
}

/// glibc's allocator (Linux), through FFI: `null` elsewhere (Android has
/// its own allocator, Windows no glibc).
class _Glibc {
  _Glibc._(this._info, this._trim);

  static final _Glibc? instance = () {
    if (!Platform.isLinux) return null;
    try {
      final lib = ffi.DynamicLibrary.process();
      return _Glibc._(
        lib.lookupFunction<_MallInfo2 Function(), _MallInfo2 Function()>(
          'mallinfo2',
        ),
        lib.lookupFunction<ffi.Int Function(ffi.Size), int Function(int)>(
          'malloc_trim',
        ),
      );
    } on Object catch (e) {
      debugPrint('memory: no glibc allocator numbers ($e)');
      return null;
    }
  }();

  final _MallInfo2 Function() _info;
  final int Function(int) _trim;

  /// In MB, over every arena: what the app's native code holds now
  /// (`malloc_used`), and the freed memory glibc keeps for reuse instead of
  /// giving it back (`malloc_free`). Freed memory counts in RSS only where
  /// its pages were touched, so this is the most trimming can return.
  Map<String, Object?> read() {
    final i = _info();
    int mb(int bytes) => (bytes / (1 << 20)).round();
    return {
      'malloc_used_mb': mb(i.uordblks + i.hblkhd),
      'malloc_free_mb': mb(i.fordblks),
    };
  }

  void trim() => _trim(0);
}

/// `struct mallinfo2` (glibc 2.33+): every field a `size_t`.
final class _MallInfo2 extends ffi.Struct {
  @ffi.Size()
  external int arena;
  @ffi.Size()
  external int ordblks;
  @ffi.Size()
  external int smblks;
  @ffi.Size()
  external int hblks;
  @ffi.Size()
  external int hblkhd;
  @ffi.Size()
  external int usmblks;
  @ffi.Size()
  external int fsmblks;
  @ffi.Size()
  external int uordblks;
  @ffi.Size()
  external int fordblks;
  @ffi.Size()
  external int keepcost;
}
