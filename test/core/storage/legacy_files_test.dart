// Moving what earlier versions left in the wrong place on desktop
// (docs/PACKAGING.md §2). The library must never be lost: copied first,
// switched into place last, never overwritten.

import 'dart:io';

import 'package:cinemakom/core/diagnostics/event_log.dart';
import 'package:cinemakom/core/platform/app_dirs.dart';
import 'package:cinemakom/core/storage/image_cache.dart';
import 'package:cinemakom/core/storage/legacy_files.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late String documents;
  late String data;

  setUp(() {
    root = Directory.systemTemp.createTempSync('cinemakom-legacy-');
    documents = p.join(root.path, 'Documents');
    data = p.join(root.path, 'share', 'io.github.sharon_xa.cinemakom');
    Directory(documents).createSync();
  });
  tearDown(() {
    AppDirs.debugCurrent = null;
    root.deleteSync(recursive: true);
  });

  File doc(String name) => File(p.join(documents, name));
  File dat(String name) => File(p.join(data, name));
  Future<LegacyMove> move() =>
      moveLegacyDatabase(from: documents, to: data, name: 'cinemakom.sqlite');

  group('the library database', () {
    test('moves with its journal files, and the old ones go', () async {
      doc('cinemakom.sqlite').writeAsStringSync('library');
      doc('cinemakom.sqlite-wal').writeAsStringSync('wal');
      doc('cinemakom.sqlite-shm').writeAsStringSync('shm');
      expect(await move(), LegacyMove.moved);
      expect(dat('cinemakom.sqlite').readAsStringSync(), 'library');
      expect(dat('cinemakom.sqlite-wal').readAsStringSync(), 'wal');
      expect(dat('cinemakom.sqlite-shm').readAsStringSync(), 'shm');
      expect(Directory(documents).listSync(), isEmpty);
      expect(
        Directory(data).listSync().where((e) => e.path.endsWith('.moving')),
        isEmpty,
      );
    });

    test('nothing to move: nothing happens', () async {
      expect(await move(), LegacyMove.none);
      expect(Directory(data).existsSync(), isFalse);
    });

    test(
      'never overwrites a library already there; the old one stays',
      () async {
        doc('cinemakom.sqlite').writeAsStringSync('old');
        dat('cinemakom.sqlite')
          ..createSync(recursive: true)
          ..writeAsStringSync('new');
        expect(await move(), LegacyMove.keptBoth);
        expect(dat('cinemakom.sqlite').readAsStringSync(), 'new');
        expect(doc('cinemakom.sqlite').readAsStringSync(), 'old');
      },
    );

    test('a copy that fails keeps the old files untouched, and leaves no '
        'half library', () async {
      doc('cinemakom.sqlite').writeAsStringSync('library');
      // The target folder can't be made: a file is in its way.
      File(data)
        ..createSync(recursive: true)
        ..writeAsStringSync('in the way');
      expect(await move(), LegacyMove.failed);
      expect(doc('cinemakom.sqlite').readAsStringSync(), 'library');
      expect(
        EventLog.instance.recent.map((e) => e.message),
        contains(startsWith("couldn't move the library")),
      );
    });

    test('stopped halfway, the next start finishes it', () async {
      doc('cinemakom.sqlite').writeAsStringSync('library');
      // A copy left by a run that stopped before the switch, plus a stale
      // companion file from an earlier aborted rename.
      dat('cinemakom.sqlite.moving')
        ..createSync(recursive: true)
        ..writeAsStringSync('lib');
      dat('cinemakom.sqlite-wal').writeAsStringSync('stale-wal');
      expect(await move(), LegacyMove.moved);
      expect(dat('cinemakom.sqlite').readAsStringSync(), 'library');
      expect(dat('cinemakom.sqlite-wal').existsSync(), isFalse);
    });

    test(
      'appDatabaseDirectory moves it to the data folder on desktop',
      () async {
        // Documents comes from path_provider, so this checks the folder
        // only; the move itself is tested above.
        AppDirs.debugCurrent = AppDirs(
          data: data,
          cache: p.join(root.path, 'cache'),
          state: p.join(root.path, 'state'),
          videos: p.join(root.path, 'Videos'),
        );
        // No path_provider in tests: the lookup of Documents fails, is
        // logged, and the data folder is still used.
        expect((await appDatabaseDirectory()).path, data);
      },
    );
  });

  group('the log', () {
    late String oldLogs;
    late String newLogs;
    setUp(() {
      oldLogs = p.join(root.path, 'share', 'logs');
      newLogs = p.join(root.path, 'state', 'logs');
    });
    Future<void> moveLogs() => moveLegacyLogs(
      from: oldLogs,
      to: newLogs,
      logNames: const [EventLog.currentName, EventLog.previousName],
    );

    test('moves to the state folder, and the old folder goes', () async {
      File(p.join(oldLogs, 'current.log'))
        ..createSync(recursive: true)
        ..writeAsStringSync('last session');
      await moveLogs();
      expect(
        File(p.join(newLogs, 'current.log')).readAsStringSync(),
        'last session',
      );
      expect(Directory(oldLogs).existsSync(), isFalse);
    });

    test('a log already in the state folder is kept', () async {
      File(p.join(oldLogs, 'current.log'))
        ..createSync(recursive: true)
        ..writeAsStringSync('old');
      File(p.join(newLogs, 'current.log'))
        ..createSync(recursive: true)
        ..writeAsStringSync('new');
      await moveLogs();
      expect(File(p.join(newLogs, 'current.log')).readAsStringSync(), 'new');
    });
  });

  test('tidy: the old font copies, poster cache and index go; other files '
      'stay', () async {
    final support = p.join(root.path, 'share');
    final temp = p.join(root.path, 'tmp');
    File(p.join(support, 'libass-fonts', 'a.ttf')).createSync(recursive: true);
    File(p.join(support, 'fonts', 'b.ttf')).createSync(recursive: true);
    File(p.join(support, 'libCachedImageData.json'))
        .createSync(recursive: true);
    File(p.join(temp, 'libCachedImageData', 'x.jpg'))
        .createSync(recursive: true);
    File(p.join(support, 'shared_preferences.json')).createSync();
    await tidyLegacyFiles(support: support, temp: temp);
    expect(Directory(p.join(support, 'libass-fonts')).existsSync(), isFalse);
    expect(Directory(p.join(support, 'fonts')).existsSync(), isFalse);
    expect(
      File(p.join(support, 'libCachedImageData.json')).existsSync(),
      isFalse,
    );
    expect(Directory(p.join(temp, 'libCachedImageData')).existsSync(), isFalse);
    expect(
      File(p.join(support, 'shared_preferences.json')).existsSync(),
      isTrue,
    );
  });

  test(
    'tidy: a fonts folder with anything but fonts in it is not ours',
    () async {
      final support = p.join(root.path, 'share');
      File(p.join(support, 'fonts', 'b.ttf')).createSync(recursive: true);
      File(p.join(support, 'fonts', 'notes.txt')).createSync();
      await tidyLegacyFiles(support: support, temp: p.join(root.path, 'tmp'));
      expect(Directory(p.join(support, 'fonts')).existsSync(), isTrue);
    },
  );

  test('the poster cache writes in its own folder, made when needed', () async {
    final dir = p.join(root.path, 'cache', 'images');
    final file = await FolderFileSystem(dir).createFile('poster.jpg');
    expect(file.path, p.join(dir, 'poster.jpg'));
    expect(Directory(dir).existsSync(), isTrue);
  });
}
