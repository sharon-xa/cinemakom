import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app/app.dart';
import 'app/widgets/broken_part.dart';
import 'core/diagnostics/diagnostics.dart';
import 'core/platform/app_dirs.dart';
import 'core/platform/full_screen.dart';
import 'core/platform/platform_info.dart';
import 'core/player/media_kit_engine.dart';
import 'core/storage/legacy_files.dart';
import 'tv/tv_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initMediaKit();
  await initPlatformInfo();
  // Desktop: the XDG folders on Linux, Local AppData on Windows
  // (docs/PACKAGING.md §2). The old log moves before the log opens it.
  await initAppDirs();
  await moveDesktopLogs();
  // The flight recorder (lib/core/diagnostics): errors, freezes and what
  // happened before them, kept on the device for Settings → Help.
  await startDiagnostics(
    ui: useTvUi
        ? 'tv'
        : isDesktop
        ? 'desktop'
        : 'phone',
  );
  BrokenPart.install();
  registerFontLicenses();

  // cached_network_image stores its cache index in sqflite, which has no
  // native plugin on Linux/Windows. Route it through the FFI implementation.
  if (isDesktop) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // No automatic provider retries: ApiClient already retries a failed GET
  // once, and the screens show errors with a "Try again" button instead of
  // a loader that silently spins.
  // The TV has its own UI (docs/TV.md). On Linux the define shows it in a
  // window the size Android TV draws apps at.
  if (useTvUi && isDesktop) setWindowContentSize(const Size(960, 540));
  unawaited(tidyLegacyFiles());
  runApp(
    ProviderScope(
      retry: noRetry,
      child: useTvUi ? const TvApp() : const CinemakomApp(),
    ),
  );
}

/// The bundled fonts' licenses (SIL OFL 1.1), for the app's licenses page.
const fontLicenses = {
  'Big Shoulders Display': 'BigShouldersDisplay-OFL.txt',
  'Reem Kufi': 'ReemKufi-OFL.txt',
  'IBM Plex Sans': 'IBMPlexSans-OFL.txt',
  'IBM Plex Sans Arabic': 'IBMPlexSansArabic-OFL.txt',
};

/// For [ProviderScope.retry]: never retry a failed provider.
Duration? noRetry(int retryCount, Object error) => null;

void registerFontLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final MapEntry(key: family, value: file) in fontLicenses.entries) {
      yield LicenseEntryWithLineBreaks([
        family,
      ], await rootBundle.loadString('assets/fonts/licenses/$file'));
    }
  });
}
