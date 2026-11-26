import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../diagnostics/event_log.dart';
import '../platform/app_dirs.dart';

// Files earlier versions left in the wrong place on desktop
// (docs/PACKAGING.md §1, P0): the library in Documents, the log in the
// data folder, posters in the temp folder. Each is moved or removed once.
// Losing the library is the one thing this must never do: a file is only
// deleted once its copy is in place, and nothing is ever overwritten.

/// What [moveLegacyDatabase] did.
enum LegacyMove {
  /// No old file.
  none,

  /// The old files are in the new folder now.
  moved,

  /// Both folders have a library: the new one is used, the old one is left.
  keptBoth,

  /// The copy failed: the old files are untouched, the new folder is
  /// used (and starts empty).
  failed,
}

/// The files SQLite may keep next to a database.
const _companions = ['-journal', '-wal', '-shm'];

/// Moves the database [name] (and its journal files) from [from] to [to],
/// when [to] has none. The files are copied first; the copies are renamed
/// into place only when all of them are written, the database last, and
/// the old files are deleted after that. If the app stops halfway, the
/// next start does it again: there's still no database in [to].
Future<LegacyMove> moveLegacyDatabase({
  required String from,
  required String to,
  required String name,
}) async {
  if (p.equals(from, to)) return LegacyMove.none;
  final old = File(p.join(from, name));
  if (!await old.exists()) return LegacyMove.none;
  final target = File(p.join(to, name));
  if (await target.exists()) {
    logEvent('app', 'a library in $from and in $to: using $to');
    return LegacyMove.keptBoth;
  }
  final parts = [
    for (final suffix in _companions)
      if (await File('${old.path}$suffix').exists()) suffix,
    '', // The database itself, last.
  ];
  final staged = <File>[];
  try {
    await Directory(to).create(recursive: true);
    // If an earlier run died mid-rename, stale companion files beside a
    // missing target database would corrupt SQLite once the DB moves in.
    for (final suffix in _companions) {
      final stale = File('${target.path}$suffix');
      if (await stale.exists()) await stale.delete();
    }
    for (final suffix in parts) {
      staged.add(
        await File('${old.path}$suffix').copy('${target.path}$suffix.moving'),
      );
    }
    for (final (i, suffix) in parts.indexed) {
      await staged[i].rename('${target.path}$suffix');
    }
  } on Object catch (e) {
    logEvent('app', "couldn't move the library from $from: $e", urgent: true);
    for (final f in staged) {
      try {
        if (await f.exists()) await f.delete();
      } on Object {
        // Left behind; the next try overwrites it.
      }
    }
    return LegacyMove.failed;
  }
  for (final suffix in parts) {
    try {
      await File('${old.path}$suffix').delete();
    } on Object catch (e) {
      logEvent('app', 'the old ${old.path}$suffix stays: $e');
    }
  }
  logEvent('app', 'moved the library from $from to $to');
  return LegacyMove.moved;
}

/// The folder the library database is in: [AppDirs.data] on desktop, the
/// library moved there from Documents first (it was drift's default).
/// Android keeps Documents, where it always was. For
/// `DriftNativeOptions.databaseDirectory`.
Future<Directory> appDatabaseDirectory() async {
  final dirs = AppDirs.current;
  final documents = getApplicationDocumentsDirectory;
  if (dirs == null) return documents();
  try {
    await moveLegacyDatabase(
      from: (await documents()).path,
      to: dirs.data,
      name: 'cinemakom.sqlite',
    );
  } on Object catch (e) {
    logEvent('app', 'no old library to look for: $e');
  }
  return Directory(dirs.data);
}

/// Moves the log files ([logNames]) from [from] to [to] when [to] has none
/// yet, so the last session's log survives the move. Before the log opens
/// its file.
Future<void> moveLegacyLogs({
  required String from,
  required String to,
  required List<String> logNames,
}) async {
  if (p.equals(from, to)) return;
  try {
    if (!await Directory(from).exists()) return;
    final target = Directory(to);
    if (await target.exists() && await target.list().isEmpty == false) return;
    await target.create(recursive: true);
    for (final name in logNames) {
      final f = File(p.join(from, name));
      if (await f.exists()) await _move(f, p.join(to, name));
    }
    await Directory(from).delete(recursive: true);
  } on Object catch (e) {
    logEvent('log', "couldn't move the old log: $e");
  }
}

/// Desktop: the log from the data folder, where earlier versions kept it,
/// to the state folder ([AppDirs.state]).
Future<void> moveDesktopLogs() async {
  final dirs = AppDirs.current;
  if (dirs == null) return;
  try {
    final support = (await getApplicationSupportDirectory()).path;
    await moveLegacyLogs(
      from: p.join(support, 'logs'),
      to: p.join(dirs.state, 'logs'),
      logNames: const [EventLog.currentName, EventLog.previousName],
    );
  } on Object catch (e) {
    logEvent('log', "couldn't look for the old log: $e");
  }
}

/// Removes what earlier versions left on desktop, in the background:
/// the subtitle font copies in the data folder (now in the cache), the
/// old poster cache in the temp folder and its index, and the old logs
/// folder if it wasn't moved. Paths are given for tests.
Future<void> tidyLegacyFiles({String? support, String? temp}) async {
  if (AppDirs.current == null && support == null) return;
  try {
    support ??= (await getApplicationSupportDirectory()).path;
    temp ??= (await getTemporaryDirectory()).path;
  } on Object {
    return;
  }
  final gone = <String>[];
  Future<void> remove(FileSystemEntity e) async {
    try {
      if (await e.exists()) {
        await e.delete(recursive: true);
        gone.add(e.path);
      }
    } on Object catch (error) {
      logEvent('app', "couldn't remove ${e.path}: $error");
    }
  }

  await remove(Directory(p.join(support, 'libass-fonts')));
  // An early build's copy of the subtitle font. Only if it holds nothing
  // else.
  final fonts = Directory(p.join(support, 'fonts'));
  if (await _onlyFonts(fonts)) await remove(fonts);
  await remove(File(p.join(support, 'libCachedImageData.json')));
  await remove(Directory(p.join(temp, 'libCachedImageData')));
  if (gone.isNotEmpty) logEvent('app', 'removed old files: ${gone.join(', ')}');
}

Future<bool> _onlyFonts(Directory dir) async {
  try {
    if (!await dir.exists()) return false;
    await for (final e in dir.list()) {
      if (e is! File || !RegExp(r'\.(ttf|otf)$').hasMatch(e.path)) {
        return false;
      }
    }
    return true;
  } on Object {
    return false;
  }
}

/// Renames [file] to [to], or copies it (another disk) and deletes it.
Future<void> _move(File file, String to) async {
  try {
    await file.rename(to);
  } on FileSystemException {
    await file.copy(to);
    await file.delete();
  }
}
