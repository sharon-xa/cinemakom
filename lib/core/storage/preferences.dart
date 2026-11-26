import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show Locale;
import 'package:shared_preferences/shared_preferences.dart';

import '../diagnostics/event_log.dart';

/// The two UI languages. English is the default.
enum AppLanguage {
  english('en'),
  arabic('ar');

  const AppLanguage(this.code);

  final String code;

  Locale get locale => Locale(code);

  static AppLanguage? fromCode(String? code) {
    for (final l in values) {
      if (l.code == code) return l;
    }
    return null;
  }
}

/// The default stream quality. The player picks the closest one a title has.
enum PreferredQuality {
  p2160(2160),
  p1080(1080),
  p720(720),
  p480(480),
  p360(360);

  const PreferredQuality(this.height);

  /// The quality class in pixels, as `VideoSource.height` reports it.
  final int height;

  static PreferredQuality? fromHeight(int? height) {
    for (final q in values) {
      if (q.height == height) return q;
    }
    return null;
  }
}

/// The default subtitle language.
enum SubtitlePreference { arabic, english, off }

/// How big subtitles are drawn (PLAYER.md §7.2). [scale] sizes the Flutter
/// layer and libass (`sub-scale`) alike.
enum SubtitleSize {
  small(0.85),
  medium(1),
  large(1.2);

  const SubtitleSize(this.scale);

  final double scale;
}

/// Whether the browsing screens on phones and tablets may turn sideways.
/// Auto by default, so the device's own auto-rotate setting decides; with
/// [portrait], browsing stays upright. The player is always landscape.
enum ScreenRotation { portrait, auto }

/// The user's settings. [language] is null until the first-launch picker
/// has been answered.
class AppSettings {
  const AppSettings({
    this.language,
    this.defaultQuality = PreferredQuality.p2160,
    this.defaultSubtitle = SubtitlePreference.arabic,
    this.subtitleSize = SubtitleSize.medium,
    this.screenRotation = ScreenRotation.auto,
    this.downloadFolder,
  });

  final AppLanguage? language;
  final PreferredQuality defaultQuality;
  final SubtitlePreference defaultSubtitle;
  final SubtitleSize subtitleSize;
  final ScreenRotation screenRotation;

  /// Desktop: the folder downloads go to; `null` means the default
  /// (`~/Videos/Cinemakom`).
  final String? downloadFolder;

  /// The language the UI shows: English until one has been chosen.
  AppLanguage get effectiveLanguage => language ?? AppLanguage.english;

  bool get hasChosenLanguage => language != null;

  AppSettings copyWith({
    AppLanguage? language,
    PreferredQuality? defaultQuality,
    SubtitlePreference? defaultSubtitle,
    SubtitleSize? subtitleSize,
    ScreenRotation? screenRotation,
    String? downloadFolder,
  }) => AppSettings(
    language: language ?? this.language,
    defaultQuality: defaultQuality ?? this.defaultQuality,
    defaultSubtitle: defaultSubtitle ?? this.defaultSubtitle,
    subtitleSize: subtitleSize ?? this.subtitleSize,
    screenRotation: screenRotation ?? this.screenRotation,
    downloadFolder: downloadFolder ?? this.downloadFolder,
  );

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.language == language &&
      other.defaultQuality == defaultQuality &&
      other.defaultSubtitle == defaultSubtitle &&
      other.subtitleSize == subtitleSize &&
      other.screenRotation == screenRotation &&
      other.downloadFolder == downloadFolder;

  @override
  int get hashCode => Object.hash(
    language,
    defaultQuality,
    defaultSubtitle,
    subtitleSize,
    screenRotation,
    downloadFolder,
  );
}

/// Key-value storage for settings. Reads are synchronous (the values are
/// cached at startup); writes are persisted asynchronously.
abstract interface class PreferenceStore {
  String? getString(String key);
  int? getInt(String key);
  Future<void> setString(String key, String value);
  Future<void> setInt(String key, int value);
}

/// [PreferenceStore] backed by shared_preferences.
///
/// Never throws, unlike the package: a value of another type (an older
/// version's, or a file edited by hand) reads as missing, a key outside
/// [PreferenceKeys.all] reads as missing and isn't saved, and a write the
/// platform refuses keeps the value for this session. Each is logged.
/// [MemoryPreferenceStore] behaves the same
/// (`test/core/preference_store_contract_test.dart`).
class SharedPreferencesStore implements PreferenceStore {
  SharedPreferencesStore._(this._prefs);

  final SharedPreferencesWithCache _prefs;

  /// The saved settings, or, when they can't be read (a damaged settings
  /// file), a [MemoryPreferenceStore]: the app starts with the defaults
  /// instead of failing on every launch.
  static Future<PreferenceStore> open() async {
    try {
      return await create();
    } on Object catch (e) {
      logEvent('settings', "can't read the saved settings: $e", urgent: true);
      return MemoryPreferenceStore();
    }
  }

  static Future<SharedPreferencesStore> create() async =>
      SharedPreferencesStore._(
        await SharedPreferencesWithCache.create(
          cacheOptions: const SharedPreferencesWithCacheOptions(
            allowList: PreferenceKeys.all,
          ),
        ),
      );

  @override
  String? getString(String key) => _read<String>(key);

  @override
  int? getInt(String key) => _read<int>(key);

  T? _read<T extends Object>(String key) {
    if (!PreferenceKeys.all.contains(key)) {
      logEvent('settings', 'read of an unknown key: $key');
      return null;
    }
    final Object? value;
    try {
      value = _prefs.get(key);
    } on Object catch (e) {
      logEvent('settings', "can't read $key: $e");
      return null;
    }
    if (value == null || value is T) return value as T?;
    logEvent('settings', '$key is a ${value.runtimeType}, not a $T: ignored');
    return null;
  }

  @override
  Future<void> setString(String key, String value) =>
      _write(key, () => _prefs.setString(key, value));

  @override
  Future<void> setInt(String key, int value) =>
      _write(key, () => _prefs.setInt(key, value));

  Future<void> _write(String key, Future<void> Function() write) async {
    if (!PreferenceKeys.all.contains(key)) {
      logEvent('settings', 'write of an unknown key: $key');
      return;
    }
    try {
      // The cache takes the value first, so it holds for this session.
      await write();
    } on Object catch (e) {
      logEvent('settings', "can't save $key: $e", urgent: true);
    }
  }
}

/// In-memory [PreferenceStore] for tests, and for a session whose saved
/// settings couldn't be read. Behaves like [SharedPreferencesStore]: keys
/// outside [PreferenceKeys.all] are neither read nor kept.
class MemoryPreferenceStore implements PreferenceStore {
  MemoryPreferenceStore([Map<String, Object>? values])
    : values = {
        for (final MapEntry(:key, :value) in (values ?? const {}).entries)
          if (PreferenceKeys.all.contains(key)) key: value,
      };

  final Map<String, Object> values;

  @override
  String? getString(String key) => switch (values[key]) {
    final String s => s,
    _ => null,
  };

  @override
  int? getInt(String key) => switch (values[key]) {
    final int i => i,
    _ => null,
  };

  @override
  Future<void> setString(String key, String value) async {
    if (PreferenceKeys.all.contains(key)) values[key] = value;
  }

  @override
  Future<void> setInt(String key, int value) async {
    if (PreferenceKeys.all.contains(key)) values[key] = value;
  }
}

abstract final class PreferenceKeys {
  static const language = 'language';
  static const defaultQuality = 'defaultQuality';
  static const defaultSubtitle = 'defaultSubtitle';
  static const subtitleSize = 'subtitleSize';
  static const screenRotation = 'screenRotation';

  /// The player's own volume on desktop, 0–100 (PLAYER.md §9.2). Phones
  /// use the system volume.
  static const playerVolume = 'playerVolume';

  /// Recent searches, a JSON list of strings, newest first.
  static const searchHistory = 'searchHistory';

  /// Desktop: where downloads go (an absolute path).
  static const downloadFolder = 'downloadFolder';

  static const all = {
    language,
    defaultQuality,
    defaultSubtitle,
    subtitleSize,
    screenRotation,
    playerVolume,
    searchHistory,
    downloadFolder,
  };
}

/// Reads [AppSettings] from [store]. Unknown or missing values fall back to
/// the defaults, so a bad stored value never breaks startup.
AppSettings readSettings(PreferenceStore store) {
  const defaults = AppSettings();
  final subtitle = store.getString(PreferenceKeys.defaultSubtitle);
  return AppSettings(
    language: AppLanguage.fromCode(store.getString(PreferenceKeys.language)),
    defaultQuality:
        PreferredQuality.fromHeight(
          store.getInt(PreferenceKeys.defaultQuality),
        ) ??
        defaults.defaultQuality,
    defaultSubtitle:
        SubtitlePreference.values.asNameMap()[subtitle] ??
        defaults.defaultSubtitle,
    subtitleSize:
        SubtitleSize.values.asNameMap()[store.getString(
          PreferenceKeys.subtitleSize,
        )] ??
        defaults.subtitleSize,
    screenRotation:
        ScreenRotation.values.asNameMap()[store.getString(
          PreferenceKeys.screenRotation,
        )] ??
        defaults.screenRotation,
    downloadFolder: switch (store.getString(PreferenceKeys.downloadFolder)) {
      final f? when f.trim().isNotEmpty => f,
      _ => null,
    },
  );
}

/// The settings store, opened once at startup ([appStartupProvider] waits
/// for it). Tests override it with a [MemoryPreferenceStore].
final preferenceStoreProvider = FutureProvider<PreferenceStore>(
  (ref) => SharedPreferencesStore.open(),
);

/// Everything the app needs before it can show its first real screen.
/// While it loads, the app shows the splash screen.
final appStartupProvider = FutureProvider<void>((ref) async {
  await ref.watch(preferenceStoreProvider.future);
});

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

class SettingsNotifier extends Notifier<AppSettings> {
  PreferenceStore get _store => ref.read(preferenceStoreProvider).requireValue;

  @override
  AppSettings build() =>
      readSettings(ref.watch(preferenceStoreProvider).requireValue);

  Future<void> setLanguage(AppLanguage language) async {
    state = state.copyWith(language: language);
    await _store.setString(PreferenceKeys.language, language.code);
  }

  Future<void> setDefaultQuality(PreferredQuality quality) async {
    state = state.copyWith(defaultQuality: quality);
    await _store.setInt(PreferenceKeys.defaultQuality, quality.height);
  }

  Future<void> setDefaultSubtitle(SubtitlePreference subtitle) async {
    state = state.copyWith(defaultSubtitle: subtitle);
    await _store.setString(PreferenceKeys.defaultSubtitle, subtitle.name);
  }

  Future<void> setSubtitleSize(SubtitleSize size) async {
    state = state.copyWith(subtitleSize: size);
    await _store.setString(PreferenceKeys.subtitleSize, size.name);
  }

  Future<void> setScreenRotation(ScreenRotation rotation) async {
    state = state.copyWith(screenRotation: rotation);
    await _store.setString(PreferenceKeys.screenRotation, rotation.name);
  }

  /// New downloads go to [folder]; the ones already saved stay where they
  /// are.
  Future<void> setDownloadFolder(String folder) async {
    state = state.copyWith(downloadFolder: folder);
    await _store.setString(PreferenceKeys.downloadFolder, folder);
  }
}
