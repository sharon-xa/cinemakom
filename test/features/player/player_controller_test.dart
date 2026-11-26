import 'package:cinemakom/core/diagnostics/event_log.dart';
import 'package:cinemakom/core/network/api_client.dart';
import 'package:cinemakom/core/network/api_endpoints.dart';
import 'package:cinemakom/core/network/api_exception.dart';
import 'package:cinemakom/core/network/api_providers.dart';
import 'package:cinemakom/core/storage/preferences.dart';
import 'package:cinemakom/data/models/localized_text.dart';
import 'package:cinemakom/data/models/media_item.dart';
import 'package:cinemakom/data/models/playback_request.dart';
import 'package:cinemakom/data/models/watch_progress.dart';
import 'package:cinemakom/data/repositories/download_store.dart';
import 'package:cinemakom/data/repositories/downloads_repository.dart';
import 'package:cinemakom/data/repositories/library_repository.dart';
import 'package:cinemakom/features/player/player_controller.dart';
import 'package:cinemakom/features/player/player_state.dart';
import 'package:cinemakom/features/player/up_next.dart';
import 'package:cinemakom/main.dart' show noRetry;
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../fixture.dart';
import '../../helpers/fake_downloader.dart';
import '../../repositories/fake_api_client.dart';
import 'fake_engine.dart';

typedef Route = (bool Function(ApiRequest), Object? Function(ApiRequest));
typedef F = FakeApiClient;

/// Streams that stay valid, so the repository's own refresh never kicks in.
List<Map<String, String>> streams([
  List<String> qualities = const ['1080p', '720p', '480p'],
  String tag = 'a',
]) => [
  for (final q in qualities)
    {
      'resolution': q,
      'videoUrl':
          'https://cdn.shabakaty.com/$tag-$q.mp4?Expires=4070908800&Signature=S',
    },
];

bool _fresh(ApiRequest r) => r.query.containsKey('_');

const movie = PlaybackRequest(
  item: MediaItem(
    id: '7',
    title: LocalizedText(en: 'Movie'),
    kind: VideoKind.movies,
  ),
);

class Env {
  Env(this.async, this.c, this.engine, this.api, this.request);

  final FakeAsync async;
  final ProviderContainer c;
  final FakeEngine engine;
  final FakeApiClient api;
  final PlaybackRequest request;

  PlayerController get controller =>
      c.read(playerControllerProvider(request).notifier);
  PlayerState get state => c.read(playerControllerProvider(request));
  int get freshRequests => api.requests.where(_fresh).length;

  void flush([Duration d = Duration.zero]) {
    async.elapse(d);
    async.flushMicrotasks();
  }
}

Env start(
  FakeAsync async, {
  List<Route> routes = const [],
  PlaybackRequest request = movie,
  Map<String, Object> prefs = const {},
  FakeEngine? fake,
  MemoryLibraryRepository? library,
  MemoryDownloadStore? downloads,
}) {
  final engine = fake ?? FakeEngine();
  final api = F([
    ...routes,
    F.path('transcoddedFiles/', streams()),
    F.fixtureAt('translationFiles/', 'subtitles_movie'),
    F.fixtureAt('allVideoInfo/', 'video_info_movie'),
    F.fixtureAt('video_thumbnails/', 'thumbnails_none'),
    F.fixtureAt('videoSeason/', 'series_episodes'),
  ]);
  final c = ProviderContainer(
    retry: noRetry,
    overrides: [
      preferenceStoreProvider.overrideWith(
        (ref) =>
            MemoryPreferenceStore({PreferenceKeys.language: 'en', ...prefs}),
      ),
      apiClientProvider.overrideWithValue(api),
      playerEngineFactoryProvider.overrideWithValue(() => engine),
      libraryRepositoryProvider.overrideWithValue(
        library ?? MemoryLibraryRepository(),
      ),
      downloadStoreProvider.overrideWithValue(
        downloads ?? MemoryDownloadStore(),
      ),
      downloaderProvider.overrideWithValue(FakeDownloader()),
    ],
  );
  c.read(preferenceStoreProvider.future);
  async.flushMicrotasks();
  c.listen(playerControllerProvider(request), (_, _) {});
  final env = Env(async, c, engine, api, request)..flush();
  return env;
}

/// The player's lines in the flight recorder.
List<String> playerLog() => [
  for (final e in EventLog.instance.recent)
    if (e.tag == 'player') e.message,
];

void main() {
  group('the flight recorder', () {
    test('a session: what changed, what was asked, at which position', () {
      fakeAsync((async) {
        final env = start(async);
        env.engine.emitReady(at: const Duration(minutes: 10));
        env.flush();
        env.controller.pause();
        env.flush();
        env.controller.play();
        env.flush();
        env.controller.seek(const Duration(minutes: 20));
        env.flush();
        env.engine.emitBuffering(true);
        env.flush();
        env.engine.emitBuffering(false);
        env.flush();
        env.controller.selectQuality(
          env.state.sources.firstWhere((s) => s.label == '720p'),
        );
        env.flush();
        env.engine.emitError('Failed to open https://cdn/x.mp4');
        env.flush(const Duration(seconds: 5));

        final log = playerLog();
        String first(String what) =>
            log.firstWhere((l) => l.contains(what), orElse: () => '');
        expect(log.first, startsWith('open 7'));
        expect(first('phase loading → ready'), isNotEmpty);
        expect(first('length 2:00:00'), isNotEmpty);
        expect(first('pause @ 10:00'), isNotEmpty);
        expect(first('playing true → false'), isNotEmpty);
        expect(first('seek to 20:00 @'), isNotEmpty);
        expect(
          log.lastWhere((l) => l.contains('buffering false → true')),
          endsWith('@ 20:00'),
        );
        expect(first('quality 720p'), isNotEmpty);
        expect(first('quality 1080p → 720p'), isNotEmpty);
        expect(first('engine error: Failed to open'), isNotEmpty);
        // In this order, each after the one before.
        var from = 0;
        for (final step in [
          'phase loading → ready',
          'pause @ 10:00',
          'play @ 10:00',
          'seek to 20:00 @ 10:00',
          'buffering false → true @ 20:00',
          'quality 720p @ 20:00',
          'engine error: Failed to open',
          'recover (engine error), attempt 1 @ 20:00',
        ]) {
          final i = log.indexWhere((l) => l.contains(step), from);
          expect(
            i,
            isNonNegative,
            reason: '"$step" after line $from:\n${log.join('\n')}',
          );
          from = i + 1;
        }
      });
    });

    test('a stall says why it recovers', () {
      fakeAsync((async) {
        final env = start(async);
        env.engine.emitReady();
        env.flush(const Duration(seconds: 20));
        expect(
          playerLog().where((l) => l.startsWith('recover (stalled)')),
          isNotEmpty,
        );
      });
    });

    test('playback moving adds no lines', () {
      fakeAsync((async) {
        // Past the fixture's intro (0–27 s): leaving it is a change.
        final env = start(async);
        env.engine.emitReady(at: const Duration(minutes: 1));
        env.flush();
        final before = playerLog().length;
        for (var s = 61; s <= 180; s++) {
          env.engine.emitPosition(Duration(seconds: s));
          env.flush(const Duration(seconds: 1));
        }
        expect(playerLog().skip(before), isEmpty);
      });
    });

    test('closing the player is a line', () {
      fakeAsync((async) {
        final env = start(async);
        env.engine.emitReady();
        env.flush();
        env.c.dispose();
        env.flush();
        expect(playerLog().last, startsWith('close @'));
      });
    });
  });

  test('opens the default quality with the shared headers and subtitles', () {
    fakeAsync((async) {
      final env = start(async);
      final open = env.engine.opened.single;
      expect(open.source.uri, contains('a-1080p'));
      expect(open.source.headers, ApiClient.defaultHeaders);
      expect(open.start, Duration.zero);
      expect(env.state.phase, PlayerPhase.loading);
      // Settings default: Arabic, drawn by Flutter (not styled).
      final sub = env.engine.subtitles.last!;
      expect((sub.language, sub.styled), ('ar', false));

      env.engine.emitReady();
      expect(env.state.phase, PlayerPhase.ready);
      expect(env.state.playing, isTrue);
    });
  });

  test('a missing preferred quality picks the nearest lower one', () {
    fakeAsync((async) {
      final env = start(
        async,
        routes: [
          F.path('transcoddedFiles/', streams(['2160p', '720p'])),
        ],
        prefs: {PreferenceKeys.defaultQuality: 1080},
      );
      expect(env.engine.opened.single.source.uri, contains('a-720p'));
    });
  });

  test('an early "completed" is a failure: fresh URLs, same position', () {
    fakeAsync((async) {
      final env = start(
        async,
        routes: [
          (
            (r) => r.path.startsWith('transcoddedFiles/') && _fresh(r),
            (_) => streams(const ['1080p', '720p'], 'b'),
          ),
        ],
      );
      env.engine.emitReady(at: const Duration(seconds: 16));
      env.engine.emitCompleted();
      env.flush();

      expect(env.freshRequests, 1);
      expect(env.engine.opened, hasLength(2));
      final reopen = env.engine.opened.last;
      expect(reopen.source.uri, contains('b-1080p'));
      expect(reopen.start, const Duration(seconds: 16));
      // The subtitle is set again after reopening.
      expect(env.engine.subtitles, hasLength(2));
      expect(env.state.phase, PlayerPhase.loading);
    });
  });

  test('"completed" near the end is the end', () {
    fakeAsync((async) {
      final env = start(async);
      env.engine.emitReady(
        duration: const Duration(minutes: 100),
        at: const Duration(minutes: 100) - const Duration(seconds: 3),
      );
      env.engine.emitCompleted();
      env.flush();
      expect(env.state.phase, PlayerPhase.ended);
      expect(env.engine.opened, hasLength(1));
    });
  });

  test('open errors retry with backoff, then fail', () {
    fakeAsync((async) {
      final env = start(async);
      for (final delay in PlayerController.recoveryDelays) {
        env.engine.emitError('Failed to open https://cdn/x.mp4.');
        env.flush(delay);
      }
      expect(
        env.engine.opened,
        hasLength(1 + PlayerController.recoveryDelays.length),
      );
      expect(env.freshRequests, PlayerController.recoveryDelays.length);
      env.engine.emitError('Failed to open https://cdn/x.mp4.');
      env.flush();
      expect(env.state.phase, PlayerPhase.failed);
      expect(env.state.error, PlayerFailure.playback);
    });
  });

  test('a decoder error moves down one quality, then fails at the bottom', () {
    fakeAsync((async) {
      final env = start(async);
      env.engine.emitReady(at: const Duration(minutes: 5));
      env.engine.emitError('decoder: renderer');
      env.flush();
      expect(env.state.quality!.height, 720);
      expect(env.state.loweredFrom!.height, 1080);
      expect(env.engine.opened.last.start, const Duration(minutes: 5));

      env.engine.emitError('decoder: renderer');
      env.flush();
      expect(env.state.quality!.height, 480);
      // Nothing lower: the usual recovery, which keeps failing.
      for (final delay in PlayerController.recoveryDelays) {
        env.engine.emitError('decoder: renderer');
        env.flush(delay);
      }
      env.engine.emitError('decoder: renderer');
      env.flush();
      expect(env.state.phase, PlayerPhase.failed);
    });
  });

  test('errors while playing are left to the player', () {
    fakeAsync((async) {
      final env = start(async);
      env.engine.emitReady();
      env.engine.emitError('tcp: Connection reset by peer');
      env.flush(const Duration(seconds: 3));
      expect(env.engine.opened, hasLength(1));
      expect(env.state.phase, PlayerPhase.ready);
    });
  });

  test('ExoPlayer stops on errors: reopened at once, paused too', () {
    fakeAsync((async) {
      final env = start(
        async,
        fake: FakeEngine(
          supportsStyledSubtitles: false,
          errorsStopPlayback: true,
        ),
        routes: [
          (
            (r) => r.path.startsWith('transcoddedFiles/') && _fresh(r),
            (_) => streams(const ['1080p', '720p'], 'b'),
          ),
        ],
      );
      env.engine.emitReady(at: const Duration(minutes: 42));
      env.controller.pause();
      env.engine.emitError('Source error: HTTP 403');
      env.flush(PlayerController.recoveryDelays.first);

      expect(env.freshRequests, 1);
      expect(env.engine.opened, hasLength(2));
      final reopen = env.engine.opened.last;
      expect(reopen.source.uri, contains('b-1080p'));
      expect(reopen.start, const Duration(minutes: 42));
      expect(reopen.play, isFalse);
    });
  });

  test('the watchdog reopens a stalled stream, but not a paused one', () {
    fakeAsync((async) {
      final env = start(async);
      env.engine.emitReady(at: const Duration(minutes: 5));

      env.controller.pause();
      env.flush(const Duration(seconds: 30));
      expect(env.engine.opened, hasLength(1));

      env.controller.play();
      env.flush(
        const Duration(seconds: PlayerController.stallLimitPlaying + 1),
      );
      expect(env.engine.opened, hasLength(2));
      expect(env.engine.opened.last.start, const Duration(minutes: 5));
    });
  });

  test('a failure refreshing the URLs shows the API error', () {
    fakeAsync((async) {
      final env = start(
        async,
        routes: [
          (
            (r) => r.path.startsWith('transcoddedFiles/') && _fresh(r),
            (_) => offline,
          ),
        ],
      );
      env.engine.emitReady();
      env.engine.emitCompleted();
      env.flush();
      expect(env.state.phase, PlayerPhase.failed);
      expect(env.state.error, isA<ApiException>());
    });
  });

  test('loading errors: API failure, and no streams at all', () {
    fakeAsync((async) {
      var env = start(async, routes: [F.path('transcoddedFiles/', offline)]);
      expect(env.state.phase, PlayerPhase.failed);
      expect(env.state.error, isA<ApiException>());
      expect(env.engine.opened, isEmpty);

      env = start(async, routes: [F.path('transcoddedFiles/', <Object?>[])]);
      expect(env.state.error, PlayerFailure.unavailable);
    });
  });

  test('switching quality keeps the position, pause and subtitle', () {
    fakeAsync((async) {
      final env = start(async);
      env.engine.emitReady(at: const Duration(minutes: 10));
      env.controller.pause();
      env.flush();
      final hd = env.state.sources.firstWhere((s) => s.height == 720);
      env.controller.selectQuality(hd);
      env.flush();

      final reopen = env.engine.opened.last;
      expect(reopen.source.uri, contains('a-720p'));
      expect(reopen.start, const Duration(minutes: 10));
      expect(reopen.play, isFalse);
      expect(env.engine.subtitles.last!.language, 'ar');

      // Opened paused: ready once buffered, and the watchdog stays quiet.
      env.engine.emitReady(at: const Duration(minutes: 10));
      env.flush(const Duration(seconds: 30));
      expect(env.state.phase, PlayerPhase.ready);
      expect(env.engine.opened, hasLength(2));
    });
  });

  test(
    'plain subtitle text is passed on; styled and failed tracks are not',
    () {
      fakeAsync((async) {
        final env = start(async);
        env.engine.emitSubtitleText([' مرحبا ', '']);
        expect(env.controller.subtitleLines.value, ['مرحبا']);

        env.engine.emitSubtitleError();
        expect(env.state.subtitle.isOff, isTrue);
        expect(env.state.subtitleFailed, isTrue);
        env.engine.emitSubtitleText(['x']);
        expect(env.controller.subtitleLines.value, isEmpty);
      });
    },
  );

  test('while a new stream opens, the clock stays where it opens, not 0:00 '
      '(mpv reports 0 until the file has loaded)', () {
    fakeAsync((async) {
      final env = start(async);
      env.engine.emitReady(at: const Duration(minutes: 108));
      env.flush();
      env.controller.selectQuality(
        env.state.sources.firstWhere((s) => s.label == '720p'),
      );
      env.flush();
      // The new file, before it has loaded and sought to the switch point.
      env.engine.emitPosition(Duration.zero);
      env.flush();
      expect(env.controller.position.value, const Duration(minutes: 108));
      expect(env.state.phase, PlayerPhase.loading);

      // Loaded: mpv lands on the keyframe a little before, and plays on.
      env.engine.emitReady(at: const Duration(minutes: 107, seconds: 58));
      env.flush();
      expect(
        env.controller.position.value,
        const Duration(minutes: 107, seconds: 58),
      );
      env.engine.emitPosition(const Duration(minutes: 108, seconds: 1));
      env.flush();
      expect(env.state.phase, PlayerPhase.ready);
      expect(
        env.controller.position.value,
        const Duration(minutes: 108, seconds: 1),
      );
    });
  });

  test('a resumed video doesn\'t show 0:00 before it lands on its place', () {
    fakeAsync((async) {
      final library = MemoryLibraryRepository([
        WatchProgress(
          videoId: '7',
          position: const Duration(minutes: 14),
          duration: const Duration(minutes: 100),
          updatedAt: DateTime(2026, 11, 19),
          title: const LocalizedText(en: 'Movie'),
        ),
      ]);
      final env = start(async, library: library);
      env.engine.emitPosition(Duration.zero);
      env.flush();
      expect(env.controller.position.value, const Duration(minutes: 14));
    });
  });

  test('an episode switch keeps the chosen quality, subtitle and speed', () {
    fakeAsync((async) {
      const series = PlaybackRequest(
        item: MediaItem(
          id: '4328',
          title: LocalizedText(en: 'Friends'),
          kind: VideoKind.series,
        ),
      );
      final env = start(async, request: series);
      expect(env.state.episodes, isNotEmpty);

      final english = env.state.subtitles.firstWhere(
        (o) => o.languageCode == 'en',
      );
      env.controller
        ..selectQuality(env.state.sources.firstWhere((s) => s.height == 480))
        ..selectSubtitle(english)
        ..setSpeed(1.5);
      env.flush();

      final next = env.state.episodes[1];
      env.controller.playEpisode(next);
      env.flush();
      expect(env.state.videoId, next.id);
      expect(env.engine.opened.last.source.uri, contains('a-480p'));
      expect(env.engine.subtitles.last!.language, 'en');
      expect(env.state.speed, 1.5);
      expect(env.engine.rate, 1.5);
    });
  });

  test('a quality switch keeps speed, subtitle delay and fit', () {
    fakeAsync((async) {
      final env = start(async);
      env.engine.emitReady(at: const Duration(minutes: 4));
      env.controller
        ..setSpeed(1.25)
        ..nudgeSubtitleDelay(const Duration(milliseconds: 500))
        ..nudgeSubtitleDelay(const Duration(milliseconds: 500))
        ..setFit(VideoFit.fill);
      env.flush();
      env.controller.selectQuality(
        env.state.sources.firstWhere((s) => s.height == 480),
      );
      env.flush();

      expect(env.engine.opened.last.start, const Duration(minutes: 4));
      expect(env.engine.opened.last.play, isTrue);
      expect(env.state.speed, 1.25);
      expect(env.engine.rate, 1.25);
      expect(env.state.subtitleDelay, const Duration(seconds: 1));
      expect(env.engine.subtitleDelay, const Duration(seconds: 1));
      expect(env.state.fit, VideoFit.fill);
      expect(env.engine.subtitles.last!.language, 'ar');
    });
  });

  test('the subtitle delay steps, resets and stays within a minute', () {
    fakeAsync((async) {
      final env = start(async);
      env.controller.nudgeSubtitleDelay(const Duration(milliseconds: -500));
      env.flush();
      expect(env.engine.subtitleDelay, const Duration(milliseconds: -500));
      env.controller.setSubtitleDelay(const Duration(minutes: 5));
      env.flush();
      expect(env.state.subtitleDelay, const Duration(seconds: 60));
      env.controller.setSubtitleDelay(Duration.zero);
      env.flush();
      expect(env.engine.subtitleDelay, Duration.zero);
    });
  });

  test('the fit cycles Fit, Fill, Stretch', () {
    fakeAsync((async) {
      final env = start(async);
      expect(env.state.fit, VideoFit.fit);
      expect(env.controller.cycleFit(), VideoFit.fill);
      expect(env.controller.cycleFit(), VideoFit.stretch);
      expect(env.controller.cycleFit(), VideoFit.fit);
    });
  });

  test('the subtitle size setting sizes libass, also when it changes', () {
    fakeAsync((async) {
      final env = start(async, prefs: {PreferenceKeys.subtitleSize: 'small'});
      expect(env.engine.subtitleScale, 0.85);
      env.c.read(settingsProvider.notifier).setSubtitleSize(SubtitleSize.large);
      env.flush();
      expect(env.engine.subtitleScale, 1.2);
    });
  });

  test('the next episode starts at 0, though the old one plays on', () {
    fakeAsync((async) {
      const series = PlaybackRequest(
        item: MediaItem(
          id: '4328',
          title: LocalizedText(en: 'Friends'),
          kind: VideoKind.series,
        ),
      );
      final env = start(async, request: series);
      env.engine.emitReady(at: const Duration(minutes: 12));
      env.controller.playEpisode(env.state.episodes[1]);
      // The old file is still playing while the new streams load.
      env.engine.emitPosition(const Duration(minutes: 12, seconds: 1));
      env.flush();
      expect(env.engine.opened.last.start, Duration.zero);
      expect(env.controller.position.value, Duration.zero);
    });
  });

  test('styled subtitles are offered only where the engine draws them', () {
    fakeAsync((async) {
      final routes = [F.fixtureAt('translationFiles/', 'subtitles_special')];
      final mpv = start(async, routes: routes);
      expect(mpv.state.subtitles.where((o) => o.isStyled), isNotEmpty);

      final exo = start(
        async,
        routes: routes,
        fake: FakeEngine(supportsStyledSubtitles: false),
      );
      expect(exo.state.subtitles.where((o) => o.isStyled), isEmpty);
      expect(exo.state.subtitles.where((o) => o.languageCode == 'ar'), [
        isA<Object>(),
      ]);
    });
  });

  test('resumes a saved position, and Start over goes back to 0', () {
    fakeAsync((async) {
      final library = MemoryLibraryRepository([
        WatchProgress(
          videoId: '7',
          position: const Duration(minutes: 14),
          duration: const Duration(minutes: 100),
          updatedAt: DateTime(2026, 11, 19),
          title: const LocalizedText(en: 'Movie'),
        ),
      ]);
      final env = start(async, library: library);
      expect(env.engine.opened.single.start, const Duration(minutes: 14));
      expect(env.state.resumedFrom, const Duration(minutes: 14));

      env.engine.emitReady(at: const Duration(minutes: 14, seconds: 1));
      env.controller.startOver();
      env.flush();
      expect(env.engine.seeks.last, Duration.zero);
      expect(env.state.resumedFrom, isNull);
    });
  });

  test('saves every 10 s while playing, on pause, and finished at the end', () {
    fakeAsync((async) {
      final library = MemoryLibraryRepository();
      final env = start(async, library: library);
      // Nothing is saved before the file opened.
      expect(library.rows, isEmpty);

      env.engine.emitReady(
        duration: const Duration(minutes: 100),
        at: const Duration(minutes: 5),
      );
      env.flush(const Duration(seconds: 10));
      final saved = library.rows['7']!;
      expect(saved.position, const Duration(minutes: 5));
      expect(saved.duration, const Duration(minutes: 100));
      expect(saved.kind, VideoKind.movies);
      expect(saved.title.en, 'Movie');
      expect(saved.seriesId, isNull);

      env.engine.emitPosition(const Duration(minutes: 6));
      env.controller.pause();
      env.flush();
      expect(library.rows['7']!.position, const Duration(minutes: 6));
      expect(library.rows['7']!.isFinished, isFalse);

      env.engine.emitPosition(const Duration(minutes: 100));
      env.engine.emitCompleted();
      env.flush();
      expect(env.state.phase, PlayerPhase.ended);
      expect(library.rows['7']!.isFinished, isTrue);
    });
  });

  test('an episode is saved with its series, season and number', () {
    fakeAsync((async) {
      const series = PlaybackRequest(
        item: MediaItem(
          id: '4328',
          title: LocalizedText(en: 'Friends'),
          kind: VideoKind.series,
        ),
      );
      final library = MemoryLibraryRepository();
      final env = start(async, request: series, library: library);
      final playing = env.state.episodes.first;
      env.controller.playEpisode(playing);
      env.flush();
      env.engine.emitReady(at: const Duration(minutes: 3));
      env.controller.playEpisode(env.state.episodes[1]);
      env.flush();
      final first = library.rows[playing.id]!;
      expect(first.seriesId, '4328');
      expect((first.season, first.episode), (playing.season, playing.episode));
      expect(first.position, const Duration(minutes: 3));
      expect(first.kind, VideoKind.series);
    });
  });

  test('closing the player disposes the engine', () {
    fakeAsync((async) {
      final env = start(async);
      env.c.dispose();
      env.flush();
      expect(env.engine.disposed, isTrue);
    });
  });
  group('Up next (PLAYER.md §7.7)', () {
    const friends = PlaybackRequest(
      item: MediaItem(
        id: '4328',
        title: LocalizedText(en: 'Friends'),
        kind: VideoKind.series,
      ),
    );
    const length = Duration(minutes: 22);
    const last5s = Duration(minutes: 21, seconds: 55);

    /// Friends, playing its first episode (the fixture has six, one per
    /// season).
    Env series(FakeAsync async) {
      final env = start(async, request: friends);
      env.controller.playEpisode(env.state.episodes.first);
      env.flush();
      return env;
    }

    test('the card shows at the finished point, then counts down', () {
      fakeAsync((async) {
        final env = series(async);
        final second = env.state.episodes[1];
        env.engine.emitReady(duration: length, at: const Duration(minutes: 19));
        expect(env.state.upNext, UpNext.none);

        env.engine.emitPosition(const Duration(minutes: 20, seconds: 30));
        expect(env.state.upNext, UpNext.card);

        env.engine.emitPosition(last5s);
        expect(env.state.upNext, UpNext.countdown);
        env.flush(upNextCountdown - const Duration(seconds: 1));
        expect(env.state.videoId, env.state.episodes.first.id);

        env.flush(const Duration(seconds: 1));
        expect(env.state.videoId, second.id);
        expect(env.state.upNext, UpNext.none);
        expect(env.engine.opened.last.start, Duration.zero);
      });
    });

    test('pause stops the countdown; Hide and a seek back hide the card', () {
      fakeAsync((async) {
        final env = series(async);
        final first = env.state.episodes.first.id;
        env.engine.emitReady(duration: length, at: last5s);
        env.controller.pause();
        env.flush(const Duration(seconds: 30));
        expect(env.state.upNext, UpNext.card);
        expect(env.state.videoId, first);

        env.controller.seek(const Duration(minutes: 5));
        env.flush();
        expect(env.state.upNext, UpNext.none);

        env.controller
          ..seek(last5s)
          ..play();
        env.flush();
        expect(env.state.upNext, UpNext.countdown);
        env.controller.hideUpNext();
        env.flush(const Duration(seconds: 30));
        expect(env.state.upNext, UpNext.none);
        expect(env.state.videoId, first);
      });
    });

    test('the countdown carries on after the file ends', () {
      fakeAsync((async) {
        final env = series(async);
        env.engine.emitReady(duration: length, at: last5s);
        env.flush(const Duration(seconds: 4));
        env.engine.emitPosition(length);
        env.engine.emitCompleted();
        expect(env.state.phase, PlayerPhase.ended);
        expect(env.state.upNext, UpNext.countdown);
        env.flush(const Duration(seconds: 6));
        expect(env.state.videoId, env.state.episodes[1].id);
      });
    });

    test('after 3 automatic episodes it pauses and asks', () {
      fakeAsync((async) {
        final env = series(async);
        void playToEnd() {
          env.engine.emitReady(duration: length, at: last5s);
          env.flush(upNextCountdown);
        }

        for (var i = 1; i <= autoEpisodesBeforeAsking; i++) {
          playToEnd();
          expect(env.state.videoId, env.state.episodes[i].id);
        }
        playToEnd();
        expect(env.state.upNext, UpNext.stillWatching);
        expect(env.engine.isPlaying, isFalse);
        expect(env.state.videoId, env.state.episodes[3].id);

        env.controller.playNext();
        env.flush();
        expect(env.state.videoId, env.state.episodes[4].id);
        expect(env.state.upNext, UpNext.none);
        expect(env.engine.opened.last.play, isTrue);
      });
    });

    test('any input starts the count again', () {
      fakeAsync((async) {
        final env = series(async);
        for (var i = 1; i <= 4; i++) {
          env.engine.emitReady(duration: length, at: last5s);
          if (i == 3) env.controller.noteActivity();
          env.flush(upNextCountdown);
          expect(env.state.videoId, env.state.episodes[i].id);
        }
      });
    });

    test('nothing comes after the last episode, or after a movie', () {
      fakeAsync((async) {
        final env = series(async);
        final last = env.state.episodes.last;
        env.controller.playEpisode(last);
        env.flush();
        env.engine.emitReady(duration: length, at: last5s);
        env.flush(const Duration(seconds: 30));
        expect(env.state.upNext, UpNext.none);
        expect(env.state.videoId, last.id);

        final movie = start(async);
        movie.engine.emitReady(duration: length, at: last5s);
        expect(movie.state.upNext, UpNext.none);
      });
    });
  });
  group('Skip intro (PLAYER.md §7.5)', () {
    /// The fixture movie with a cold open (0–12 s) and an intro (230–291 s).
    Env twoIntros(FakeAsync async) => start(
      async,
      routes: [
        F.path('allVideoInfo/', {
          ...fixture('video_info_movie')! as Map<String, Object?>,
          'introSkipping': [
            {'start': '0', 'end': '11.9', 'control_level': '3'},
            {'start': '230', 'end': '291', 'control_level': '3'},
          ],
        }),
      ],
    );

    test('each range gets its own button, pinned for 8 s', () {
      fakeAsync((async) {
        final env = twoIntros(async);
        env.engine.emitReady(at: const Duration(seconds: 1));
        final cold = env.state.intro!;
        expect(cold.end, const Duration(milliseconds: 11900));
        expect(env.state.introPinned, isTrue);

        env.engine.emitPosition(const Duration(seconds: 20));
        expect(env.state.intro, isNull);

        env.engine.emitPosition(const Duration(seconds: 231));
        expect(env.state.intro!.start, const Duration(seconds: 230));
        expect(env.state.introPinned, isTrue);
        env.flush(PlayerController.introPinnedFor);
        expect(env.state.introPinned, isFalse);
        expect(env.state.intro, isNotNull);

        // Back into the first range: the button shows with the controls only.
        env.engine.emitPosition(const Duration(seconds: 2));
        expect(env.state.intro, cold);
        expect(env.state.introPinned, isFalse);
      });
    });

    test('Skip intro jumps to the end of the range', () {
      fakeAsync((async) {
        final env = twoIntros(async);
        env.engine.emitReady(at: const Duration(seconds: 240));
        env.controller.skipIntro();
        env.flush();
        expect(env.engine.seeks.last, const Duration(seconds: 291));
        expect(env.state.intro, isNull);
      });
    });

    test('nothing shows on a title without intro ranges', () {
      fakeAsync((async) {
        final env = start(
          async,
          routes: [F.fixtureAt('allVideoInfo/', 'video_info_special')],
        );
        env.engine.emitReady(at: const Duration(seconds: 5));
        expect(env.state.intro, isNull);
        env.controller.skipIntro();
        env.flush();
        expect(env.engine.seeks, isEmpty);
      });
    });
  });
  group('desktop controls (PLAYER.md §9.2)', () {
    test('the volume is saved and comes back next time', () {
      fakeAsync((async) {
        final env = start(async, prefs: {PreferenceKeys.playerVolume: 40});
        expect(env.state.volume, 40);
        env.controller.changeVolume(-5);
        env.flush();
        expect(env.engine.volume, 35);
        final store = env.c.read(preferenceStoreProvider).requireValue;
        expect(store.getInt(PreferenceKeys.playerVolume), 35);
        env.controller.changeVolume(200);
        env.flush();
        expect(env.state.volume, 100);
      });
    });

    test('mute keeps the volume; a key up from mute starts at 0', () {
      fakeAsync((async) {
        final env = start(async, prefs: {PreferenceKeys.playerVolume: 60});
        env.controller.toggleMute();
        env.flush();
        expect(env.state.muted, isTrue);
        expect(env.engine.volume, 0);
        env.controller.toggleMute();
        env.flush();
        expect(env.engine.volume, 60);

        env.controller.toggleMute();
        env.controller.changeVolume(5);
        env.flush();
        expect(env.state.muted, isFalse);
        expect(env.engine.volume, 5);
      });
    });

    test('C cycles the subtitles, 0-9 jump to tenths', () {
      fakeAsync((async) {
        final env = start(async);
        env.engine.emitReady(duration: const Duration(minutes: 100));
        final options = env.state.subtitles;
        final at = options.indexOf(env.state.subtitle);
        env.controller.nextSubtitle();
        env.flush();
        expect(env.state.subtitle, options[(at + 1) % options.length]);

        env.controller.seekToTenth(3);
        env.flush();
        expect(env.engine.seeks.last, const Duration(minutes: 30));
        env.controller.seekToTenth(0);
        env.flush();
        expect(env.engine.seeks.last, Duration.zero);
      });
    });
  });
}
