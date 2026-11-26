// Windows P1 interactive UI pass (docs/PACKAGING.md §4):
// 150% and 200% DPI scaling across all screens (EN and AR), Arabic keyboard
// input in Search, and fullscreen enter/exit on Windows.

import 'package:cinemakom/app/app.dart';
import 'package:cinemakom/app/router.dart';
import 'package:cinemakom/core/storage/preferences.dart';
import 'package:cinemakom/features/player/player_screen.dart';
import 'package:cinemakom/features/search/search_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/app_harness.dart';
import 'player/fake_engine.dart';

void main() {
  for (final (:label, :width, :height, :dpr) in const [
    (
      label: '150% DPI (1080p work area)',
      width: 1280.0,
      height: 688.0,
      dpr: 1.5,
    ),
    (
      label: '200% DPI (1080p work area)',
      width: 960.0,
      height: 516.0,
      dpr: 2.0,
    ),
  ]) {
    for (final lang in const ['en', 'ar']) {
      testWidgets(
        'all tabs, details, and player render cleanly at $label ($lang)',
        (tester) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.windows;
          final engine = FakeEngine();
          final fullScreen = FakeFullScreen();
          final store = MemoryPreferenceStore({PreferenceKeys.language: lang});
          try {
            await pumpApp(
              tester,
              store: store,
              engine: engine,
              fullScreen: fullScreen,
              width: width,
              height: height,
              devicePixelRatio: dpr,
            );
            final router = ProviderScope.containerOf(
              tester.element(find.byType(CinemakomApp)),
            ).read(routerProvider);

            // Home, Search, Library, Downloads, Settings, Activity Log.
            for (final path in const [
              AppRoutes.home,
              AppRoutes.search,
              AppRoutes.library,
              AppRoutes.downloads,
              AppRoutes.settings,
              AppRoutes.activityLog,
              '/home/title/3119279',
            ]) {
              router.go(path);
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull, reason: 'Failed on $path');
            }

            // Player + fullscreen toggle + restore on exit.
            router.push('/watch/3119279');
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 500));
            engine.emitReady(duration: const Duration(hours: 2));
            await tester.pump();
            expect(find.byType(PlayerScreen), findsOneWidget);
            expect(tester.takeException(), isNull);

            await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
            await tester.pump();
            expect(fullScreen.isOn, isTrue);

            // Popping while fullscreen restores windowed state.
            router.pop();
            await tester.pump();
            await tester.pump(const Duration(seconds: 1));
            expect(fullScreen.isOn, isFalse);
            expect(tester.takeException(), isNull);
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        },
      );
    }
  }

  testWidgets('Arabic keyboard input in Search works in both EN and AR UI', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      for (final lang in const ['en', 'ar']) {
        final store = MemoryPreferenceStore({PreferenceKeys.language: lang});
        await pumpApp(
          tester,
          store: store,
          width: 1280,
          height: 688,
          devicePixelRatio: 1.5,
        );
        final router = ProviderScope.containerOf(
          tester.element(find.byType(CinemakomApp)),
        ).read(routerProvider);
        router.go(AppRoutes.search);
        await tester.pumpAndSettle();
        expect(find.byType(SearchScreen), findsOneWidget);

        const arabicQuery = 'باتمان الظلام';
        await tester.enterText(find.byType(TextField), arabicQuery);
        await tester.pump(searchDebounce + const Duration(milliseconds: 50));
        await tester.pumpAndSettle();
        expect(find.text(arabicQuery), findsWidgets);

        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();

        // Clear search and verify the Arabic query was saved in Recent searches.
        await tester.tap(find.byIcon(Icons.close).first);
        await tester.pumpAndSettle();
        expect(find.text(arabicQuery), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox());
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
