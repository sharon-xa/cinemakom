import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:qr_flutter/qr_flutter.dart';

import 'package:cinemakom/core/network/api_endpoints.dart';
import 'package:cinemakom/core/storage/preferences.dart';
import 'package:cinemakom/core/downloads/downloader.dart';
import 'package:cinemakom/data/models/download.dart';
import 'package:cinemakom/data/models/localized_text.dart';
import 'package:cinemakom/data/models/watch_progress.dart';
import 'package:cinemakom/data/repositories/download_store.dart';
import 'package:cinemakom/data/repositories/library_repository.dart';
import 'package:cinemakom/tv/screens/details/tv_details_screen.dart';
import 'package:cinemakom/tv/tv_app.dart';

import '../helpers/app_harness.dart';
import '../helpers/fake_downloader.dart';
import 'reachability.dart';
import 'tv_driver.dart';

// The Search, Library, Downloads and Settings tabs on TV (docs/TV.md TV-5),
// on fixture data, each reached the way the remote does: Up to the tabs,
// along them, Down into the tab.

final _exits = <String>[];
const _min = Duration(minutes: 1);

WatchProgress _movie() => WatchProgress(
  videoId: '3119279',
  position: _min * 40,
  duration: _min * 100,
  updatedAt: DateTime(2026, 11, 19, 12, 2),
  title: const LocalizedText(en: 'Eve of Destruction'),
  kind: VideoKind.movies,
);

WatchProgress _episode() => WatchProgress(
  videoId: '4401',
  seriesId: '4328',
  season: 2,
  episode: 1,
  position: _min * 10,
  duration: _min * 22,
  updatedAt: DateTime(2026, 11, 19, 12, 1),
  title: const LocalizedText(en: 'Friends'),
  kind: VideoKind.series,
);

final _dir = Directory.systemTemp.createTempSync('tv-dl').path;

Download _download(
  String id, {
  String titleId = '3119279',
  String title = 'Eve of Destruction',
  DownloadStatus status = DownloadStatus.complete,
  int? season,
  int? episode,
  bool createFile = true,
}) {
  if (status == DownloadStatus.complete && createFile) {
    final f = File(p.join(_dir, '$id.mp4'));
    if (!f.existsSync()) f.writeAsBytesSync(const [0]);
  }
  return Download(
    videoId: id,
    titleId: titleId,
    title: LocalizedText(en: title),
    season: season,
    episode: episode,
    kind: season == null ? VideoKind.movies : VideoKind.series,
    quality: '1080p',
    baseDirectory: 'root',
    directory: _dir,
    fileName: '$id.mp4',
    status: status,
    totalBytes: 2 * 1024 * 1024 * 1024,
    addedAt: DateTime(2026, 11, 19),
  );
}

/// The app on TV, then [tab] (1 Search … 4 Settings) by remote.
Future<TvDriver> _openTab(
  WidgetTester tester,
  int tab, {
  bool arabic = false,
  List<String> history = const [],
  MemoryLibraryRepository? library,
  MemoryDownloadStore? downloads,
  int? freeSpace,
  FakeDownloader? downloader,
}) async {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'SystemNavigator.pop') _exits.add('exit');
      return null;
    },
  );
  _exits.clear();
  await tester.pumpWidget(const SizedBox());
  await pumpApp(
    tester,
    tv: true,
    library: library,
    downloads: downloads,
    downloader: downloader,
    freeSpace: freeSpace,
    store: MemoryPreferenceStore({
      PreferenceKeys.language: arabic ? 'ar' : 'en',
      if (history.isNotEmpty) PreferenceKeys.searchHistory: jsonEncode(history),
    }),
  );
  final tv = TvDriver(tester);
  await tv.up();
  for (var i = 0; i < tab; i++) {
    // The tabs run along the screen's reading direction (R12).
    arabic ? await tv.left() : await tv.right();
  }
  await tv.down();
  return tv;
}

void main() {
  group('Search', () {
    testWidgets('opens on the box; recent searches, Clear all, genres', (
      tester,
    ) async {
      final tv = await _openTab(tester, 1, history: ['dune', 'friends']);
      expect(tv.focused, 'Titles, actors, directors');
      await tv.down();
      expect(tv.focused, 'All');
      await tv.down();
      expect(tv.focused, 'dune');
      await tv.right();
      expect(tv.focused, 'Remove “dune”');
      // Down keeps the cell.
      await tv.down();
      expect(tv.focused, 'Remove “friends”');
      await tv.ok();
      expect(find.text('friends'), findsNothing);
      // Focus moves on to what's left (R7).
      expect(tv.focused, isNot(startsWith('not a TV item')));
    });

    testWidgets('typing searches; a result opens and Back comes back to it', (
      tester,
    ) async {
      final tv = await _openTab(tester, 1);
      await tv.ok();
      await tester.enterText(find.byType(TextField), 'eve');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      // Done: back to the D-pad, on the box.
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      await tv.down();
      await tv.down();
      await tv.right();
      final result = tv.focused;
      await tv.ok();
      expect(find.byType(TvDetailsScreen), findsOneWidget);
      await tv.back();
      expect(find.byType(TvDetailsScreen), findsNothing);
      expect(tv.focused, result);
      // Opening it remembered the search.
      final store = ProviderScope.containerOf(
        tester.element(find.byType(TvApp)),
      ).read(preferenceStoreProvider).requireValue;
      expect(store.getString(PreferenceKeys.searchHistory), contains('eve'));
    });
  });

  group('Library', () {
    testWidgets('Continue rows: resume, Details, Remove; then Favorites', (
      tester,
    ) async {
      final library = MemoryLibraryRepository([_movie(), _episode()]);
      final tv = await _openTab(tester, 2, library: library);
      expect(tv.focused, 'Continue watching');
      await tv.down();
      expect(tv.focused, startsWith('Eve of Destruction'));
      await tv.right();
      expect(tv.focused, 'Details');
      await tv.right();
      expect(tv.focused, 'Remove');
      await tv.ok();
      // The movie is gone; focus is on the row that moved up.
      expect(find.textContaining('Eve of Destruction'), findsNothing);
      expect(tv.focused, 'Remove');
      await tv.left();
      await tv.left();
      expect(tv.focused, startsWith('Friends'));

      await tv.up();
      await tv.right();
      expect(tv.focused, 'Favorites');
      expect(
        find.text('Pick Favorite on any title to keep it here.'),
        findsOneWidget,
      );
    });
  });

  group('Downloads', () {
    testWidgets('empty: says so, and Browse Home goes Home', (tester) async {
      final tv = await _openTab(tester, 3);
      expect(tv.focused, 'Browse Home');
      await tv.ok();
      expect(tv.focused, anyOf('Home', 'Play'));
    });

    testWidgets('a movie and a series; the series opens its episodes', (
      tester,
    ) async {
      final store = MemoryDownloadStore([
        _download('3119279'),
        _download(
          '4401',
          titleId: '4328',
          title: 'Friends',
          season: 2,
          episode: 1,
        ),
        _download(
          '4402',
          titleId: '4328',
          title: 'Friends',
          season: 3,
          episode: 1,
        ),
      ]);
      final tv = await _openTab(
        tester,
        3,
        downloads: store,
        freeSpace: 3 * 1024 * 1024 * 1024,
      );
      expect(find.textContaining('free on this TV'), findsOneWidget);
      expect(tv.focused, anyOf(startsWith('Eve'), startsWith('Friends')));
      // To the series' row, then its episodes.
      for (var i = 0; i < 2 && !tv.focused.startsWith('Friends'); i++) {
        await tv.down();
      }
      expect(tv.focused, contains('2 episodes'));
      await tv.ok();
      expect(tv.focused, startsWith('Season 2 · Episode 1'));
      await tv.right();
      expect(tv.focused, 'Delete');
      await tv.ok();
      // Asks first, on the safe answer.
      expect(tv.focused, 'Keep it');
      await tv.back();
      expect(tv.focused, 'Delete');
      // Back to the row that opened the page (R2).
      await tv.back();
      expect(tv.focused, contains('2 episodes'));
    });

    testWidgets('paused and failed rows show saved bytes on TV', (
      tester,
    ) async {
      const gb = 1024 * 1024 * 1024;
      final store = MemoryDownloadStore([
        Download(
          videoId: 'p1',
          titleId: 'p1',
          title: const LocalizedText(en: 'The Odyssey'),
          kind: VideoKind.movies,
          quality: '2160p',
          baseDirectory: 'root',
          directory: _dir,
          fileName: 'p1.mp4',
          status: DownloadStatus.paused,
          pausedByUser: true,
          totalBytes: 27 * gb,
          downloadedBytes: (3.6 * gb).round(),
          addedAt: DateTime(2026, 11, 21),
        ),
        Download(
          videoId: 'f1',
          titleId: 'f1',
          title: const LocalizedText(en: 'Dune'),
          kind: VideoKind.movies,
          quality: '1080p',
          baseDirectory: 'root',
          directory: _dir,
          fileName: 'f1.mp4',
          status: DownloadStatus.failed,
          problem: DownloadProblem.interrupted,
          totalBytes: 4 * gb,
          downloadedBytes: 1 * gb,
          addedAt: DateTime(2026, 11, 20),
        ),
      ]);
      await _openTab(
        tester,
        3,
        downloads: store,
        freeSpace: 50 * gb,
        // Its partial file is gone, so it waits for the user's Retry rather
        // than continuing by itself.
        downloader: FakeDownloader()..resumeAllowed = false,
      );
      expect(find.textContaining('3.6 GB of 27 GB'), findsOneWidget);
      expect(find.textContaining('Stopped: interrupted'), findsOneWidget);
      expect(find.textContaining('1.0 GB of 4.0 GB'), findsOneWidget);
    });

    testWidgets('a download that finishes on screen turns into its row', (
      tester,
    ) async {
      final store = MemoryDownloadStore([
        _download('3119279', status: DownloadStatus.running, createFile: false),
      ]);
      final downloader = FakeDownloader();
      final tv = await _openTab(
        tester,
        3,
        downloads: store,
        downloader: downloader,
      );
      expect(tv.focused, startsWith('Eve of Destruction'));
      downloader.send(
        const DownloaderProgress(
          '3119279',
          fraction: 0.99,
          expectedBytes: 2 * 1024 * 1024 * 1024,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('99%'), findsOneWidget);
      await tester.runAsync(() async {
        File(p.join(_dir, '3119279.mp4')).writeAsBytesSync(const [0]);
        downloader.knownStates['3119279'] = DownloaderState.complete;
        downloader.send(
          const DownloaderStatus('3119279', DownloaderState.complete),
        );
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await tester.pump();
        }
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('99%'), findsNothing);
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets(
      'a failed row: Try again · Details · Cancel; Details says why',
      (tester) async {
        final store = MemoryDownloadStore([
          Download(
            videoId: 'f1',
            titleId: 'f1',
            title: const LocalizedText(en: 'Dune'),
            kind: VideoKind.movies,
            quality: '1080p',
            baseDirectory: 'root',
            directory: _dir,
            fileName: 'f1.mp4',
            status: DownloadStatus.failed,
            problem: DownloadProblem.interrupted,
            problemDetail: 'HTTP 403 from the CDN',
            totalBytes: 4 * 1024 * 1024 * 1024,
            downloadedBytes: 1024 * 1024 * 1024,
            addedAt: DateTime(2026, 11, 20),
          ),
        ]);
        final tv = await _openTab(
          tester,
          3,
          downloads: store,
          downloader: FakeDownloader()..resumeAllowed = false,
        );
        expect(tv.focused, startsWith('Dune'));
        await tv.right();
        expect(tv.focused, 'Try again');
        await tv.right();
        expect(tv.focused, 'Details');
        await tv.ok();
        expect(find.textContaining('Engine message: HTTP 403'), findsOneWidget);
        expect(
          find.textContaining('Progress: 1.0 GB of 4.0 GB'),
          findsOneWidget,
        );
        expect(tv.focused, 'Try again');
        await tv.back();
        expect(tv.focused, 'Details');
        await tv.right();
        expect(tv.focused, 'Cancel');
      },
    );

    testWidgets(
      'missing finished movie shows File removed and Download again on TV',
      (tester) async {
        final goneDir = Directory.systemTemp.createTempSync('tv-gone').path;
        addTearDown(() => Directory(goneDir).deleteSync(recursive: true));
        final store = MemoryDownloadStore([
          Download(
            videoId: '3119279',
            titleId: '3119279',
            title: const LocalizedText(en: 'Eve of Destruction'),
            kind: VideoKind.movies,
            quality: '1080p',
            baseDirectory: 'root',
            directory: goneDir,
            fileName: 'missing.mp4',
            status: DownloadStatus.complete,
            totalBytes: 2 * 1024 * 1024 * 1024,
            addedAt: DateTime(2026, 11, 21),
          ),
        ]);
        final tv = await _openTab(tester, 3, downloads: store);
        expect(find.text('File removed'), findsOneWidget);
        await tv.right();
        expect(tv.focused, 'Download again');
      },
    );
  });

  group('Settings', () {
    testWidgets('Arabic in place, focus kept on the Language row', (
      tester,
    ) async {
      final tv = await _openTab(tester, 4);
      expect(tv.focused, 'Language, English');
      await tv.ok();
      expect(tv.focused, 'English');
      await tv.down();
      await tv.ok();
      expect(tv.focused, 'اللغة, العربية');
      expect(
        Directionality.of(tester.element(find.text('اللغة'))),
        TextDirection.rtl,
      );
    });

    testWidgets('a value panel opens on the current choice', (tester) async {
      final tv = await _openTab(tester, 4);
      await tv.down();
      expect(tv.focused, startsWith('Default quality'));
      await tv.ok();
      expect(tv.focused, '2160p · 4K');
      await tv.back();
      expect(tv.focused, startsWith('Default quality'));
    });

    testWidgets('the end shows the name and mark; panels never move the page', (
      tester,
    ) async {
      final tv = await _openTab(tester, 4);
      await tv.focusLabel('About and licenses');
      final mark = tester.getRect(find.text('Cinemakom').last);
      expect(mark.bottom, lessThanOrEqualTo(540));
      double offset() => tester
          .stateList<ScrollableState>(find.byType(Scrollable))
          .firstWhere((s) => s.position.axis == Axis.vertical)
          .position
          .pixels;
      // Up past Activity log, GitHub and Report a bug.
      for (var i = 0; i < 4; i++) {
        await tv.up();
      }
      expect(tv.focused, startsWith('Subtitle size'));
      final before = offset();
      final markBefore = tester.getRect(find.text('Cinemakom').last);
      await tv.ok();
      await tv.back();
      expect(tv.focused, startsWith('Subtitle size'));
      expect(offset(), before);
      expect(tester.getRect(find.text('Cinemakom').last), markBefore);
      // Back up from the end: every row shows as it's focused (the ring
      // check in each press), up to the first.
      await tv.up();
      await tv.up();
      await tv.up();
      expect(tv.focused, startsWith('Language'));
    });

    testWidgets('About and licenses lists the packages; Back returns', (
      tester,
    ) async {
      final tv = await _openTab(tester, 4);
      await tv.focusLabel('About and licenses');
      await tv.ok();
      expect(find.text('ABOUT AND LICENSES'), findsOneWidget);
      await tv.back();
      expect(tv.focused, 'About and licenses');
    });

    testWidgets('Report a bug shows the email and GitHub codes; Back returns', (
      tester,
    ) async {
      final tv = await _openTab(tester, 4);
      await tv.focusLabel('Report a bug');
      await tv.ok();
      expect(find.text("Scan with your phone's camera"), findsOneWidget);
      expect(find.byType(QrImageView), findsNWidgets(2));
      expect(find.text('me@sharon-xa.com'), findsOneWidget);
      expect(tv.focused, 'OK');
      await tv.back();
      expect(tv.focused, 'Report a bug');
      await tv.down();
      expect(tv.focused, 'Cinemakom on GitHub');
      await tv.ok();
      expect(find.byType(QrImageView), findsOneWidget);
      await tv.ok();
      expect(tv.focused, 'Cinemakom on GitHub');
    });
  });

  for (final arabic in [false, true]) {
    final lang = arabic ? 'Arabic' : 'English';
    for (final (tab, name) in [
      (1, 'Search'),
      (2, 'Library'),
      (3, 'Downloads'),
      (4, 'Settings'),
    ]) {
      testWidgets('no traps in $name ($lang)', (tester) async {
        await expectNoTraps(
          tester,
          pumpScreen: () => _openTab(
            tester,
            tab,
            arabic: arabic,
            history: const ['dune'],
            library: MemoryLibraryRepository([_movie(), _episode()]),
            downloads: MemoryDownloadStore([
              _download('3119279'),
              _download(
                '4401',
                titleId: '4328',
                title: 'Friends',
                season: 2,
                episode: 1,
              ),
            ]),
          ),
          leftScreen: () => _exits.isNotEmpty,
          backChecks: 6,
        );
      });
    }
  }
}
