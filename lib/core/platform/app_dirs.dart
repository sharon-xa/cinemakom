import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_windows/path_provider_windows.dart';

import '../diagnostics/event_log.dart';
import 'platform_info.dart';

/// The app's ID: the Linux application ID, the folder name under the XDG
/// folders, and the Flatpak ID (docs/PACKAGING.md).
const appId = 'io.github.sharon_xa.cinemakom';

/// Where the app keeps its own files on desktop (docs/PACKAGING.md §2):
/// the XDG folders on Linux, Local AppData on Windows. Android keeps its
/// folders as they were, so [current] is `null` there (and in tests).
///
/// Packages that pick their own folder stay where they are: settings
/// (shared_preferences) and the download engine's state use the app
/// support folder, which is `$XDG_DATA_HOME/<id>` on Linux and Roaming
/// AppData on Windows.
@immutable
class AppDirs {
  const AppDirs({
    required this.data,
    required this.cache,
    required this.state,
    required this.videos,
  });

  /// The library database.
  final String data;

  /// What can be rebuilt any time: posters, the subtitle font.
  final String cache;

  /// The activity log (`<state>/logs`).
  final String state;

  /// The user's videos folder; downloads go in `Cinemakom` in it.
  final String videos;

  static AppDirs? _current;

  /// The folders, once [initAppDirs] ran on desktop.
  static AppDirs? get current => _current;

  @visibleForTesting
  static set debugCurrent(AppDirs? dirs) => _current = dirs;

  @override
  String toString() =>
      'data $data · cache $cache · state $state · videos $videos';
}

/// Finds the folders, once, before `runApp`. Never throws: on a problem the
/// app keeps the packages' defaults.
Future<void> initAppDirs() async {
  if (!isDesktop) return;
  try {
    final env = Platform.environment;
    if (isLinux) {
      final home = env['HOME'] ?? Directory.current.path;
      final configHome = xdgBase(env, 'XDG_CONFIG_HOME', home, '.config');
      final userDirs = File(p.posix.join(configHome, 'user-dirs.dirs'));
      AppDirs._current = linuxAppDirs(
        env: env,
        home: home,
        userDirs: userDirs.existsSync() ? userDirs.readAsStringSync() : null,
      );
    } else if (isWindows) {
      // %LOCALAPPDATA%\io.github.sharon_xa\Cinemakom (Runner.rc's names).
      final local = (await getApplicationCacheDirectory()).path;
      String? videos;
      try {
        videos = await PathProviderWindows().getPath(_videosFolderId);
      } on Object catch (e) {
        logEvent('app', "can't find the Videos folder: $e");
      }
      AppDirs._current = windowsAppDirs(
        local: local,
        videos: videos == null || videos.isEmpty
            ? p.join(env['USERPROFILE'] ?? local, 'Videos')
            : videos,
      );
    }
    logEvent('app', 'folders: ${AppDirs._current}');
  } on Object catch (e) {
    logEvent('app', "can't find the app's folders: $e");
  }
}

/// FOLDERID_Videos: the Videos known folder, wherever the user moved it.
/// (`WindowsKnownFolder.Videos` is only defined on Windows builds.)
const _videosFolderId = '{18989B1D-99B5-455B-841C-AB7C74E4DDFC}';

/// The folders on Linux, by the XDG Base Directory and user-dirs specs.
/// [userDirs] is the text of `$XDG_CONFIG_HOME/user-dirs.dirs`, if any.
/// Always `/` paths (`p.posix`), so the tests check them on Windows too.
AppDirs linuxAppDirs({
  required Map<String, String> env,
  required String home,
  String? userDirs,
}) => AppDirs(
  data: p.posix.join(
    xdgBase(env, 'XDG_DATA_HOME', home, '.local/share'),
    appId,
  ),
  cache: p.posix.join(xdgBase(env, 'XDG_CACHE_HOME', home, '.cache'), appId),
  state: p.posix.join(
    xdgBase(env, 'XDG_STATE_HOME', home, '.local/state'),
    appId,
  ),
  videos: xdgUserDir(
    'VIDEOS',
    fallback: 'Videos',
    env: env,
    home: home,
    userDirs: userDirs,
  ),
);

/// The folders on Windows: everything in [local] (the app's Local AppData
/// folder, not synced between PCs), downloads in [videos] (the Videos known
/// folder, wherever the user moved it).
AppDirs windowsAppDirs({required String local, required String videos}) =>
    AppDirs(
      data: local,
      cache: p.windows.join(local, 'cache'),
      state: local,
      videos: videos,
    );

/// `$name` if it's an absolute path, else `~/<fallback>`. The spec says a
/// relative value is invalid and must be ignored.
String xdgBase(
  Map<String, String> env,
  String name,
  String home,
  String fallback,
) {
  final value = env[name];
  if (value != null && value.isNotEmpty && p.posix.isAbsolute(value)) {
    return value;
  }
  return p.posix.join(home, fallback);
}

/// A user folder (`VIDEOS`, `DOWNLOAD`, …) as `xdg-user-dir` gives it: the
/// `XDG_<name>_DIR` line of [userDirs], else that variable in [env], else
/// `~/<fallback>`. A value of just `$HOME` means the folder is turned off;
/// the fallback is used then too (no files straight in the home).
String xdgUserDir(
  String name, {
  required String fallback,
  required Map<String, String> env,
  required String home,
  String? userDirs,
}) {
  final key = 'XDG_${name}_DIR';
  String? expand(String? raw) {
    if (raw == null) return null;
    var v = raw.trim();
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      v = v.substring(1, v.length - 1);
    }
    if (v == r'$HOME' || v.startsWith(r'$HOME/')) {
      v = home + v.substring(5);
    }
    v = p.posix.normalize(v);
    if (!p.posix.isAbsolute(v) || p.posix.equals(v, home)) return null;
    return v;
  }

  String? fromFile;
  for (final line in (userDirs ?? '').split('\n')) {
    final l = line.trim();
    if (l.startsWith('#') || !l.startsWith('$key=')) continue;
    fromFile = expand(l.substring(key.length + 1));
  }
  return fromFile ?? expand(env[key]) ?? p.posix.join(home, fallback);
}
