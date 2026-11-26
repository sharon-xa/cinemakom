import 'dart:io';

import 'package:cinemakom/data/models/download.dart';
import 'package:cinemakom/data/models/localized_text.dart';
import 'package:cinemakom/data/models/media_item.dart';
import 'package:cinemakom/data/models/playback_models.dart';
import 'package:cinemakom/data/repositories/download_paths.dart';
import 'package:cinemakom/data/repositories/download_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('resolvePlatformDownloadRoot', () {
    test('Android API 30+ and API 29 use public Movies/Cinemakom', () {
      for (final sdk in [29, 30, 35]) {
        final root = resolvePlatformDownloadRoot(
          isDesktopPlatform: false,
          isAndroidPlatform: true,
          androidSdkInt: sdk,
          publicMoviesDir: '/storage/emulated/0/Movies/Cinemakom',
          externalAppDir: '/storage/emulated/0/Android/data/pkg/files',
        );
        expect(root.baseDirectory, 'root');
        expect(root.directory, '/storage/emulated/0/Movies/Cinemakom');
      }
    });

    test(
      'Android API 24-28 uses Movies/Cinemakom only with storage permission',
      () {
        final granted = resolvePlatformDownloadRoot(
          isDesktopPlatform: false,
          isAndroidPlatform: true,
          androidSdkInt: 28,
          publicMoviesDir: '/storage/emulated/0/Movies/Cinemakom',
          hasLegacyStorage: true,
          externalAppDir: '/storage/emulated/0/Android/data/pkg/files',
        );
        expect(granted.directory, '/storage/emulated/0/Movies/Cinemakom');

        final denied = resolvePlatformDownloadRoot(
          isDesktopPlatform: false,
          isAndroidPlatform: true,
          androidSdkInt: 28,
          publicMoviesDir: '/storage/emulated/0/Movies/Cinemakom',
          hasLegacyStorage: false,
          externalAppDir: '/storage/emulated/0/Android/data/pkg/files',
        );
        expect(
          denied.directory,
          p.join('/storage/emulated/0/Android/data/pkg/files', 'Downloads'),
        );
      },
    );

    test('desktop uses chosen folder or default ~/Videos/Cinemakom', () {
      final custom = resolvePlatformDownloadRoot(
        isDesktopPlatform: true,
        isAndroidPlatform: false,
        desktopFolder: '/data/movies',
      );
      expect(custom.baseDirectory, 'root');
      expect(custom.directory, '/data/movies');

      final def = resolvePlatformDownloadRoot(
        isDesktopPlatform: true,
        isAndroidPlatform: false,
      );
      expect(def.directory, defaultDesktopFolder());
    });
  });

  group('naming & clash resolution', () {
    test('folder includes year when known, sanitizes illegal chars', () {
      const movie = MediaItem(
        id: '1',
        title: LocalizedText(en: 'Spider-Man: No Way Home?'),
        year: 2021,
      );
      expect(
        titleFolderName(movie, fallback: '1'),
        'Spider-Man No Way Home (2021)',
      );
      const noYear = MediaItem(
        id: '2',
        title: LocalizedText(en: 'Friends'),
      );
      expect(titleFolderName(noYear, fallback: '2'), 'Friends');
    });

    test('videoFileStem handles movies, episodes and double episodes', () {
      const series = MediaItem(
        id: '4328',
        title: LocalizedText(en: 'Friends'),
      );
      expect(
        videoFileStem(
          series,
          episode: Episode(id: 'e1', season: 1, episode: 2),
          quality: '1080p',
          fallback: 'e1',
        ),
        'Friends S01E02 1080p',
      );
      expect(
        videoFileStem(
          series,
          episode: Episode(
            id: 'e2',
            season: 1,
            episode: 7,
            numbering: const EpisodeNumbering(7, last: 8),
          ),
          quality: '720p',
          fallback: 'e2',
        ),
        'Friends S01E07-E08 720p',
      );
    });

    test('uniqueFileStem adds (2), (3) on existing files', () {
      final dir = Directory.systemTemp.createTempSync('dl-unique');
      addTearDown(() => dir.deleteSync(recursive: true));

      expect(uniqueFileStem(dir.path, 'The Odyssey 4K'), 'The Odyssey 4K');
      File(p.join(dir.path, 'The Odyssey 4K.mp4')).writeAsBytesSync([1]);
      expect(uniqueFileStem(dir.path, 'The Odyssey 4K'), 'The Odyssey 4K (2)');
      File(p.join(dir.path, 'The Odyssey 4K (2).mp4')).writeAsBytesSync([1]);
      expect(uniqueFileStem(dir.path, 'The Odyssey 4K'), 'The Odyssey 4K (3)');
    });

    test('uniqueFileStem skips names a download on its way holds', () {
      final dir = Directory.systemTemp.createTempSync('dl-unique');
      addTearDown(() => dir.deleteSync(recursive: true));
      final taken = {
        takenKey(p.join(dir.path, 'the odyssey 4k.mp4')),
        takenKey(p.join(dir.path, '.', 'The Odyssey 4K (2).mp4')),
      };
      expect(
        uniqueFileStem(dir.path, 'The Odyssey 4K', taken: taken),
        'The Odyssey 4K (3)',
      );
      expect(uniqueFileStem(dir.path, 'Other', taken: taken), 'Other');
    });
  });

  group('migrateLegacyDownloads', () {
    test(
      'moves finished Phase 6 video and subtitles into Movies/Cinemakom',
      () async {
        final root = Directory.systemTemp.createTempSync('dl-migrate');
        addTearDown(() => root.deleteSync(recursive: true));
        final legacyRoot = p.join(root.path, 'Android', 'Downloads');
        final targetRoot = p.join(root.path, 'Movies', 'Cinemakom');

        final oldFolder = p.join(legacyRoot, 'The Odyssey');
        Directory(oldFolder).createSync(recursive: true);
        File(p.join(oldFolder, 'The Odyssey 1080p.mp4'))
            .writeAsBytesSync([1, 2, 3]);
        File(p.join(oldFolder, 'The Odyssey 1080p.ar.srt'))
            .writeAsStringSync('sub');

        // Pre-existing file at target causes (2) clash resolution.
        final existingTarget = p.join(targetRoot, 'The Odyssey');
        Directory(existingTarget).createSync(recursive: true);
        File(p.join(existingTarget, 'The Odyssey 1080p.mp4'))
            .writeAsBytesSync([9]);

        final store = MemoryDownloadStore([
          Download(
            videoId: 'm1',
            titleId: 'm1',
            title: const LocalizedText(en: 'The Odyssey'),
            quality: '1080p',
            baseDirectory: 'root',
            directory: oldFolder,
            fileName: 'The Odyssey 1080p.mp4',
            subtitles: const [
              DownloadedSubtitle(
                language: 'ar',
                fileName: 'The Odyssey 1080p.ar.srt',
                format: 'srt',
              ),
            ],
            totalBytes: 3,
            downloadedBytes: 3,
            status: DownloadStatus.complete,
            addedAt: DateTime(2026, 11, 20),
          ),
          // An unfinished Phase 6 row starts over in the new folder.
          Download(
            videoId: 'm2',
            titleId: 'm2',
            title: const LocalizedText(en: 'Active'),
            quality: '720p',
            baseDirectory: 'root',
            directory: p.join(legacyRoot, 'Active'),
            fileName: 'Active 720p.mp4',
            status: DownloadStatus.paused,
            addedAt: DateTime(2026, 11, 20),
          ),
        ]);

        final scanned = <String>[];
        final cancelled = <String>[];
        final moved = await migrateLegacyDownloads(
          store: store,
          legacyRoot: legacyRoot,
          targetRoot: targetRoot,
          pathOf: (d) async => p.join(d.directory, d.fileName),
          onMoved: (path) async => scanned.add(path),
          cancelTask: (id) async => cancelled.add(id),
        );

        expect(moved.moved, 1);
        expect(moved.restarted, ['m2']);
        expect(cancelled, ['m2']);
        final active = (await store.get('m2'))!;
        expect(active.directory, p.join(targetRoot, 'Active'));
        expect(active.fileName, 'Active 720p.mp4');
        expect(active.status, DownloadStatus.failed);
        final row = (await store.get('m1'))!;
        expect(row.directory, existingTarget);
        expect(row.fileName, 'The Odyssey 1080p (2).mp4');
        expect(row.subtitles.single.fileName, 'The Odyssey 1080p (2).ar.srt');
        expect(File(p.join(row.directory, row.fileName)).readAsBytesSync(), [
          1,
          2,
          3,
        ]);
        expect(
          File(p.join(row.directory, row.subtitles.single.fileName))
              .readAsStringSync(),
          'sub',
        );
        expect(scanned, [p.join(row.directory, row.fileName)]);
        expect(Directory(oldFolder).existsSync(), isFalse);
      },
    );
  });

  test(
    'Windows hides .partial folder (including spaces and Arabic paths)',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final root = Directory.systemTemp.createTempSync('dl-partial ');
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        root.deleteSync(recursive: true);
      });
      final moved = Directory(p.join(root.path, 'الفيديو', 'Cinemakom'))
        ..createSync(recursive: true);
      final partial = await platformPartialDir((
        baseDirectory: 'root',
        directory: moved.path,
      ));
      expect(partial, p.join(moved.path, '.partial'));
      expect(Directory(partial!).existsSync(), isTrue);
      final attrib = await Process.run('attrib', [partial]);
      expect(attrib.exitCode, 0);
      // attrib output puts 'H' in the attributes prefix before the path.
      final prefix = (attrib.stdout as String).split(partial).first;
      expect(prefix, contains('H'));
    },
    skip: !Platform.isWindows,
  );
}
