// Downloads on slow connections and with huge files (docs/DOWNLOADS.md
// §5.5): the real background_downloader and the live CDN, a 240p episode.
//
// 1. A final failure keeps the partial file's resume data: Retry continues
//    from the saved bytes instead of starting over.
// 2. A URL about to expire is replaced before the engine starts a run.
//
//   WAYLAND_DISPLAY=wayland-1 DISPLAY=:1 \
//     fvm flutter test integration_test/downloads_recovery_test.dart -d linux
import 'dart:io';

import 'package:cinemakom/core/downloads/background_file_downloader.dart';
import 'package:cinemakom/core/downloads/downloader.dart';
import 'package:cinemakom/core/network/api_client.dart';
import 'package:cinemakom/data/models/playback_models.dart';
import 'package:cinemakom/data/repositories/media_repository.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

const videoId = '4328'; // Friends S1E1, about 47 MB at 240p.

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  // One engine per process: retries 0, so a failure is final at once.
  final engine = BackgroundFileDownloader(retries: 0);
  final events = <DownloaderEvent>[];
  late VideoSource source;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('cinemakom-recovery');
    engine.events.listen((e) {
      events.add(e);
      if (e is DownloaderStatus) debugPrint('[recovery] status $e');
    });
    await engine.start(partialDir: p.join(dir.path, '.partial'));
    source = (await MediaRepository(
      ApiClient(),
    ).streams(videoId, fresh: true)).firstWhere((s) => s.label == '240p');
  });
  tearDownAll(() => dir.deleteSync(recursive: true));

  DownloadJob job(String url, String name) => DownloadJob(
    taskId: videoId,
    url: url,
    headers: {...ApiClient.defaultHeaders, 'Range': 'bytes=0-'},
    spot: FileSpot('root', dir.path, name),
    displayName: 'Friends',
    quality: '240p',
  );

  Future<T> until<T>(
    String what,
    T? Function() found, {
    int seconds = 90,
  }) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (true) {
      if (found() case final value?) return value;
      if (DateTime.now().isAfter(end)) fail('Timed out waiting for $what');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  setUp(() {
    events.clear();
  });

  DownloaderState? lastState() =>
      events.whereType<DownloaderStatus>().lastOrNull?.state;

  double lastFraction() =>
      events.whereType<DownloaderProgress>().lastOrNull?.fraction ?? 0;

  test('a final failure keeps the partial file: Retry continues from the '
      'saved bytes', () async {
    events.clear();
    expect(await engine.enqueue(job(source.url, 'kept.mp4')), isTrue);
    await until('10%', () => lastFraction() >= 0.1 ? true : null);
    expect(await engine.pause(videoId), isTrue);
    await until(
      'paused',
      () => lastState() == DownloaderState.paused ? true : null,
    );
    final saved = lastFraction();
    debugPrint('[recovery] paused at ${(saved * 100).toStringAsFixed(1)}%');

    // A URL nothing answers: with no retries left the failure is final, and
    // background_downloader clears the resume data. (The CDN doesn't always
    // check signatures, so a broken one wouldn't fail: docs/API.md §3.)
    events.clear();
    final refused = Uri.parse(source.url)
        .replace(scheme: 'https', host: '127.0.0.1', port: 1)
        .toString();
    expect(await engine.resume(videoId, refused), isTrue);
    final failed = await until(
      'failed',
      () => events
          .whereType<DownloaderStatus>()
          .where((e) => e.state == DownloaderState.failed)
          .firstOrNull,
    );
    debugPrint('[recovery] failed: HTTP ${failed.httpCode} ${failed.detail}');
    // Still continuable: the app kept it.
    expect(await engine.canResume(videoId), isTrue);

    events.clear();
    expect(await engine.resume(videoId, source.url), isTrue);
    await until(
      'progress after Retry',
      () => events.whereType<DownloaderProgress>().firstOrNull,
    );
    final first = events.whereType<DownloaderProgress>().first.fraction;
    debugPrint(
      '[recovery] Retry starts at ${(first * 100).toStringAsFixed(1)}%',
    );
    expect(first, greaterThanOrEqualTo(saved - 0.01));

    await until(
      'complete',
      () => lastState() == DownloaderState.complete ? true : null,
      seconds: 180,
    );
    final size = await ApiClient().contentLength(source.url);
    expect(File(p.join(dir.path, 'kept.mp4')).lengthSync(), size);
  }, timeout: const Timeout(Duration(minutes: 6)));

  test('a URL about to expire is replaced before the run starts', () async {
    events.clear();
    await engine.cancel(videoId);
    // Says it expires in 10 minutes, on a host nothing answers: only the
    // fresh URL from the refresh can download anything.
    final soon =
        DateTime.now()
            .add(const Duration(minutes: 10))
            .millisecondsSinceEpoch ~/
        1000;
    final expiring = Uri.parse(source.url)
        .replace(
          host: '127.0.0.1',
          port: 1,
          queryParameters: {
            ...Uri.parse(source.url).queryParameters,
            'Expires': '$soon',
          },
        )
        .toString();
    expect(await engine.enqueue(job(expiring, 'fresh.mp4')), isTrue);
    await until(
      'progress',
      () => lastFraction() > 0.02 ? true : null,
      seconds: 60,
    );
    expect(
      events.whereType<DownloaderStatus>().map((e) => e.state),
      isNot(contains(DownloaderState.failed)),
    );
    await engine.cancel(videoId);
    // Wait for the desktop isolate to close its partial file handle before
    // tearDownAll removes the temp directory (Windows fails delete with EBUSY
    // while a file is still open).
    await until(
      'canceled',
      () => lastState() == DownloaderState.canceled ? true : null,
      seconds: 15,
    );
  });
}
