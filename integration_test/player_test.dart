// The player end to end (PLAYER.md §11): the real app, the live API and the
// real engine. A movie: open from Details, play, seek, change quality,
// leave, then Resume. An episode: play, then Next episode.
//
//   fvm flutter test integration_test/player_test.dart -d linux
//
// History is kept in memory, so the owner's real watch history is untouched.
import 'package:cinemakom/app/app.dart';
import 'package:cinemakom/app/router.dart';
import 'package:cinemakom/core/network/api_endpoints.dart';
import 'package:cinemakom/core/storage/preferences.dart';
import 'package:cinemakom/data/models/localized_text.dart';
import 'package:cinemakom/data/models/media_item.dart';
import 'package:cinemakom/data/models/playback_request.dart';
import 'package:cinemakom/data/repositories/library_repository.dart';
import 'package:cinemakom/features/details/details_screen.dart';
import 'package:cinemakom/features/player/player_controller.dart';
import 'package:cinemakom/features/player/player_screen.dart';
import 'package:cinemakom/features/player/player_state.dart';
import 'package:cinemakom/main.dart' show noRetry;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' show MediaKit;

/// Avengers: Infinity War: several qualities, previews, an intro range.
const movieId = '191463';

/// Attack on Titan, a series with many episodes.
const series = PlaybackRequest(
  item: MediaItem(
    id: '279230',
    title: LocalizedText(en: 'Attack on Titan'),
    kind: VideoKind.series,
    rootSeriesId: '279230',
  ),
  episodeId: '279230',
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  MediaKit.ensureInitialized();

  /// Pumps real time until [done], or fails after [seconds].
  Future<void> until(
    WidgetTester tester,
    String what,
    bool Function() done, {
    int seconds = 30,
  }) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (!done()) {
      if (DateTime.now().isAfter(end)) fail('Timed out waiting for $what');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
  }

  Future<void> wait(WidgetTester tester, Duration d) async {
    final end = DateTime.now().add(d);
    while (DateTime.now().isBefore(end)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
  }

  ProviderContainer container(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(CinemakomApp)));

  /// The open player's controller and state.
  PlayerController controller(WidgetTester tester) {
    final request = tester.widget<PlayerScreen>(find.byType(PlayerScreen));
    return container(tester)
        .read(playerControllerProvider(request.request).notifier);
  }

  PlayerState state(WidgetTester tester) => controller(tester).state;

  bool playing(WidgetTester tester) =>
      find.byType(PlayerScreen).evaluate().isNotEmpty &&
      state(tester).phase == PlayerPhase.ready &&
      state(tester).playing;

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(1280, 720)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        retry: noRetry,
        overrides: [
          preferenceStoreProvider.overrideWith(
            (ref) => MemoryPreferenceStore({PreferenceKeys.language: 'en'}),
          ),
          libraryRepositoryProvider.overrideWithValue(
            MemoryLibraryRepository(),
          ),
        ],
        child: const CinemakomApp(),
      ),
    );
    await wait(tester, const Duration(seconds: 1));
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k) async {
    await tester.sendKeyEvent(k);
    await tester.pump();
  }

  testWidgets('a movie: play, seek, quality, leave, resume', (tester) async {
    await pumpApp(tester);
    container(tester).read(routerProvider).push('/home/title/$movieId');
    final playOnDetails = find.descendant(
      of: find.byType(DetailsScreen),
      matching: find.text('Play'),
    );
    await until(tester, 'Details', () => playOnDetails.evaluate().isNotEmpty);
    await tester.tap(playOnDetails);
    await until(tester, 'playback', () => playing(tester));

    await wait(tester, const Duration(seconds: 5));
    final c = controller(tester);
    expect(c.position.value, greaterThan(const Duration(seconds: 3)));

    // Seek: 0–9 jump to tenths, then +10 s.
    await key(tester, LogicalKeyboardKey.digit3);
    await key(tester, LogicalKeyboardKey.arrowRight);
    final target = state(tester).duration * 0.3 + const Duration(seconds: 10);
    await until(
      tester,
      'the seek to $target (at ${c.position.value}, '
      '${state(tester).phase})',
      () => playing(tester) && c.position.value >= target,
    );

    // Change quality from the chip: same place, still playing.
    final before = state(tester).quality!;
    final other = state(tester).sources.firstWhere((s) => s.url != before.url);
    final at = c.position.value;
    await tester.tap(find.text(before.label).first);
    await wait(tester, const Duration(milliseconds: 500));
    await tester.tap(find.text(other.label).last);
    await until(
      tester,
      'the new quality',
      () => playing(tester) && state(tester).quality!.url == other.url,
    );
    expect(
      (c.position.value - at).abs(),
      lessThan(const Duration(seconds: 15)),
    );
    final leftAt = c.position.value;

    // Leave, then Resume from Details.
    await key(tester, LogicalKeyboardKey.escape);
    await until(
      tester,
      'Details again',
      () => find.textContaining('Resume').evaluate().isNotEmpty,
    );
    await tester.tap(find.textContaining('Resume').first);
    await until(tester, 'the resumed playback', () => playing(tester));
    final resumed = controller(tester).position.value;
    expect((resumed - leftAt).abs(), lessThan(const Duration(seconds: 15)));
    // The quality picked in the menu holds for the session.
    await key(tester, LogicalKeyboardKey.escape);
    await wait(tester, const Duration(seconds: 1));
  });

  testWidgets('an episode: play, then Next episode', (tester) async {
    await pumpApp(tester);
    container(tester).read(routerProvider).push('/watch/279230', extra: series);
    await until(tester, 'playback', () => playing(tester), seconds: 45);
    final first = state(tester).videoId;
    final next = state(tester).nextEpisode;
    expect(next, isNotNull);

    await key(tester, LogicalKeyboardKey.keyN);
    await until(
      tester,
      'the next episode',
      () => playing(tester) && state(tester).videoId == next!.id,
      seconds: 45,
    );
    expect(state(tester).videoId, isNot(first));
    expect(find.textContaining('Episode'), findsWidgets);
    await key(tester, LogicalKeyboardKey.escape);
    await wait(tester, const Duration(seconds: 1));
  });
}
