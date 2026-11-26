import 'package:cinemakom/core/storage/preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('readSettings', () {
    test('a fresh install has no language and the default playback', () {
      final settings = readSettings(MemoryPreferenceStore());
      expect(settings.language, isNull);
      expect(settings.hasChosenLanguage, isFalse);
      expect(settings.effectiveLanguage, AppLanguage.english);
      expect(settings.defaultQuality, PreferredQuality.p2160);
      expect(settings.defaultSubtitle, SubtitlePreference.arabic);
      expect(settings.subtitleSize, SubtitleSize.medium);
      expect(settings.screenRotation, ScreenRotation.auto);
    });

    test('reads stored values', () {
      final settings = readSettings(
        MemoryPreferenceStore({
          PreferenceKeys.language: 'ar',
          PreferenceKeys.defaultQuality: 1080,
          PreferenceKeys.defaultSubtitle: 'off',
          PreferenceKeys.subtitleSize: 'large',
          PreferenceKeys.screenRotation: 'portrait',
        }),
      );
      expect(settings.language, AppLanguage.arabic);
      expect(settings.defaultQuality, PreferredQuality.p1080);
      expect(settings.defaultSubtitle, SubtitlePreference.off);
      expect(settings.subtitleSize, SubtitleSize.large);
      expect(settings.screenRotation, ScreenRotation.portrait);
    });

    test('unknown or mistyped values fall back to the defaults', () {
      final settings = readSettings(
        MemoryPreferenceStore({
          PreferenceKeys.language: 'fr',
          PreferenceKeys.defaultQuality: 1440,
          PreferenceKeys.defaultSubtitle: 42,
          PreferenceKeys.subtitleSize: 'huge',
          PreferenceKeys.screenRotation: 'sideways',
        }),
      );
      expect(settings, const AppSettings());
    });
  });

  group('SettingsNotifier', () {
    late MemoryPreferenceStore store;
    late ProviderContainer container;

    setUp(() async {
      store = MemoryPreferenceStore();
      container = ProviderContainer(
        overrides: [preferenceStoreProvider.overrideWith((ref) => store)],
      );
      await container.read(appStartupProvider.future);
    });

    tearDown(() => container.dispose());

    test('saves each change and updates the state', () async {
      final notifier = container.read(settingsProvider.notifier);
      await notifier.setLanguage(AppLanguage.arabic);
      await notifier.setDefaultQuality(PreferredQuality.p720);
      await notifier.setDefaultSubtitle(SubtitlePreference.english);
      await notifier.setSubtitleSize(SubtitleSize.small);
      await notifier.setScreenRotation(ScreenRotation.portrait);

      expect(
        container.read(settingsProvider),
        const AppSettings(
          language: AppLanguage.arabic,
          defaultQuality: PreferredQuality.p720,
          defaultSubtitle: SubtitlePreference.english,
          subtitleSize: SubtitleSize.small,
          screenRotation: ScreenRotation.portrait,
        ),
      );
      expect(store.values, {
        PreferenceKeys.language: 'ar',
        PreferenceKeys.defaultQuality: 720,
        PreferenceKeys.defaultSubtitle: 'english',
        PreferenceKeys.subtitleSize: 'small',
        PreferenceKeys.screenRotation: 'portrait',
      });
      // A restart reads back the same settings.
      expect(readSettings(store), container.read(settingsProvider));
    });
  });
}
