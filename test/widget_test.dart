import 'package:cinemakom/app/brand/cinemakom_mark.dart';
import 'package:cinemakom/app/l10n/app_localizations.dart';
import 'package:cinemakom/core/storage/preferences.dart';
import 'package:cinemakom/features/home/home_screen.dart';
import 'package:cinemakom/features/onboarding/language_screen.dart';
import 'package:cinemakom/features/settings/settings_screen.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/app_harness.dart';

void main() {
  test('Arabic and English are both supported', () {
    expect(
      AppLocalizations.supportedLocales.map((l) => l.languageCode),
      containsAll(['en', 'ar']),
    );
  });

  group('first launch', () {
    testWidgets('asks for the language before showing Home', (tester) async {
      await pumpApp(tester, store: MemoryPreferenceStore());

      expect(find.byType(LanguageScreen), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
      expect(find.byType(CinemakomLogo), findsOneWidget);
      // The heading is shown in both languages.
      expect(find.text('Choose your language'), findsOneWidget);
      expect(find.text('اختر لغتك'), findsOneWidget);
    });

    testWidgets('picking Arabic previews RTL, Continue saves it', (
      tester,
    ) async {
      final store = MemoryPreferenceStore();
      await pumpApp(tester, store: store);
      expect(directionAt(tester, find.text('Continue')), TextDirection.ltr);

      await tester.tap(find.text('العربية'));
      await tester.pumpAndSettle();
      expect(find.text('متابعة'), findsOneWidget);
      expect(directionAt(tester, find.text('متابعة')), TextDirection.rtl);
      expect(store.values, isEmpty, reason: 'nothing is saved before Continue');

      await tester.tap(find.text('متابعة'));
      await tester.pumpAndSettle();

      expect(store.values[PreferenceKeys.language], 'ar');
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.text('الرئيسية'), findsOneWidget);
      expect(directionAt(tester, find.byType(HomeScreen)), TextDirection.rtl);
    });

    testWidgets('a returning user goes straight to Home', (tester) async {
      await pumpApp(
        tester,
        store: MemoryPreferenceStore({PreferenceKeys.language: 'en'}),
      );
      expect(find.byType(LanguageScreen), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(directionAt(tester, find.byType(HomeScreen)), TextDirection.ltr);
    });
  });

  group('tabs', () {
    testWidgets('switch between the five tabs', (tester) async {
      await pumpApp(
        tester,
        store: MemoryPreferenceStore({PreferenceKeys.language: 'en'}),
      );
      for (final (label, title) in [
        ('Search', 'SEARCH'),
        ('Library', 'LIBRARY'),
        ('Downloads', 'DOWNLOADS'),
        ('Settings', 'SETTINGS'),
      ]) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(find.text(title), findsOneWidget, reason: label);
      }
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    for (final (width, layout) in [
      (390.0, 'bar'),
      (800.0, 'rail'),
      (1300.0, 'extended rail'),
    ]) {
      testWidgets('uses a $layout at $width dp', (tester) async {
        await pumpApp(
          tester,
          store: MemoryPreferenceStore({PreferenceKeys.language: 'en'}),
          width: width,
        );
        final rail = find.byType(NavigationRail);
        switch (layout) {
          case 'bar':
            expect(find.byType(NavigationBar), findsOneWidget);
            expect(rail, findsNothing);
          case 'rail':
            expect(find.byType(NavigationBar), findsNothing);
            expect(tester.widget<NavigationRail>(rail).extended, isFalse);
          default:
            expect(tester.widget<NavigationRail>(rail).extended, isTrue);
        }
      });
    }
  });

  group('settings', () {
    Future<void> openSettings(WidgetTester tester) async {
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
    }

    testWidgets('changing the language switches the app live', (tester) async {
      final store = MemoryPreferenceStore({PreferenceKeys.language: 'en'});
      await pumpApp(tester, store: store);
      await openSettings(tester);

      await tester.tap(find.text('Language'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('العربية').last);
      await tester.pumpAndSettle();

      expect(store.values[PreferenceKeys.language], 'ar');
      expect(find.text('الإعدادات'), findsWidgets);
      expect(find.text('الجودة الافتراضية'), findsOneWidget);
      expect(
        directionAt(tester, find.byType(SettingsScreen)),
        TextDirection.rtl,
      );
      // The Settings tab is still the one showing.
      expect(find.byType(SettingsScreen), findsOneWidget);
    });

    testWidgets('quality and subtitle choices are saved', (tester) async {
      final store = MemoryPreferenceStore({PreferenceKeys.language: 'en'});
      await pumpApp(tester, store: store);
      await openSettings(tester);
      expect(find.text('2160p · 4K'), findsOneWidget);
      expect(find.text('Arabic'), findsOneWidget);

      await tester.tap(find.text('Default quality'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1080p'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Default subtitles'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Off'));
      await tester.pumpAndSettle();

      expect(find.text('1080p'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget);
      expect(store.values[PreferenceKeys.defaultQuality], 1080);
      expect(store.values[PreferenceKeys.defaultSubtitle], 'off');

      await tester.tap(find.text('Subtitle size'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Large'));
      await tester.pumpAndSettle();
      expect(find.text('Large'), findsOneWidget);
      expect(store.values[PreferenceKeys.subtitleSize], 'large');
    });

    testWidgets('screen rotation follows the device until locked to portrait', (
      tester,
    ) async {
      final calls = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemChrome.setPreferredOrientations') {
            calls.add(call.arguments);
          }
          return null;
        },
      );
      final store = MemoryPreferenceStore({PreferenceKeys.language: 'en'});
      await pumpApp(tester, store: store);
      // No preference: the system's auto-rotate decides.
      expect(calls.last, isEmpty);
      await openSettings(tester);
      expect(find.text('Rotate with device'), findsOneWidget);

      await tester.tap(find.text('Screen rotation'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Portrait only'));
      await tester.pumpAndSettle();

      expect(find.text('Portrait only'), findsOneWidget);
      expect(store.values[PreferenceKeys.screenRotation], 'portrait');
      expect(calls.last, ['DeviceOrientation.portraitUp']);
    });

    testWidgets('settings survive a restart', (tester) async {
      final store = MemoryPreferenceStore({PreferenceKeys.language: 'en'});
      await pumpApp(tester, store: store);
      await openSettings(tester);
      await tester.tap(find.text('Default quality'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('720p'));
      await tester.pumpAndSettle();

      // A new app (new ProviderScope) on the same storage.
      await tester.pumpWidget(const SizedBox());
      await pumpApp(tester, store: store);
      await openSettings(tester);
      expect(find.text('720p'), findsOneWidget);
    });
  });
}
