import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import '../platform/platform_info.dart';
import 'event_log.dart';

/// The app's memory, as far as each platform lets an app see it
/// (docs/MEMORY.md §4). Sizes are bytes; a part the platform can't show is
/// `null`. GPU memory on desktop isn't in any of these.
class MemorySample {
  const MemorySample({
    required this.rss,
    required this.maxRss,
    this.imageBytes,
    this.images,
    this.liveImages,
    this.anonymous,
    this.fileBacked,
    this.android = const {},
  });

  /// Resident memory now, and the most it has been.
  final int rss;
  final int maxRss;

  /// Linux and Android (`/proc/self/smaps_rollup`): the resident memory
  /// that no file backs (allocations: heaps, buffers, decoded frames), and
  /// the part that maps files (code, fonts, the disk cache).
  final int? anonymous;
  final int? fileBacked;

  /// Flutter's decoded image cache: its bytes, its images, and the images
  /// on screen (which stay even past the cache's limit). `null` before
  /// Flutter has started (the player controller's unit tests).
  final int? imageBytes;
  final int? images;
  final int? liveImages;

  /// Android: what `dumpsys meminfo` sums (`java-heap`, `native-heap`,
  /// `graphics`, `code`, `stack`, `private-other`, `system`, `total-pss`,
  /// `total-swap`), from `Debug.MemoryInfo`. Empty elsewhere.
  final Map<String, int> android;

  /// What the flight recorder keeps: the parts that cost nothing to read.
  String describe() => [
    'rss ${_mb(rss)} MB',
    if (imageBytes != null)
      'images ${_mb(imageBytes!)} MB ($images, $liveImages on screen)',
  ].join(', ');

  /// Whole megabytes, for the memory test's JSON.
  Map<String, Object?> toJson() => {
    'rss_mb': _mb(rss),
    'max_rss_mb': _mb(maxRss),
    'anon_mb': ?_mbOrNull(anonymous),
    'file_mb': ?_mbOrNull(fileBacked),
    'images_mb': ?_mbOrNull(imageBytes),
    'images': ?images,
    'live_images': ?liveImages,
    if (android.isNotEmpty)
      'android_mb': {for (final e in android.entries) e.key: _mb(e.value)},
  };
}

int _mb(int bytes) => (bytes / (1 << 20)).round();
int? _mbOrNull(int? bytes) => bytes == null ? null : _mb(bytes);

/// The parts that need no I/O: resident memory and the image cache.
MemorySample readMemoryNow() {
  ImageCache? cache;
  try {
    cache = PaintingBinding.instance.imageCache;
  } on Object {
    cache = null;
  }
  return MemorySample(
    rss: ProcessInfo.currentRss,
    maxRss: ProcessInfo.maxRss,
    imageBytes: cache?.currentSizeBytes,
    images: cache?.currentSize,
    liveImages: cache?.liveImageCount,
  );
}

/// Everything the platform shows. Reads a file on Linux and Android, and
/// asks the platform on Android, so it's for the memory test, not for
/// every frame.
Future<MemorySample> readMemory() async {
  final now = readMemoryNow();
  Map<String, int>? rollup;
  if (Platform.isLinux || isAndroid) {
    try {
      rollup = parseSmapsRollup(
        await File('/proc/self/smaps_rollup').readAsString(),
      );
    } on Object {
      rollup = null;
    }
  }
  return MemorySample(
    rss: now.rss,
    maxRss: now.maxRss,
    imageBytes: now.imageBytes,
    images: now.images,
    liveImages: now.liveImages,
    anonymous: rollup?['Anonymous'],
    fileBacked: rollup == null
        ? null
        : (rollup['Rss'] ?? 0) - (rollup['Anonymous'] ?? 0),
    android: isAndroid ? await _androidMemory() : const {},
  );
}

/// `Rss:  4024 kB` lines of `/proc/self/smaps_rollup`, in bytes by name.
Map<String, int> parseSmapsRollup(String text) {
  final sizes = <String, int>{};
  for (final line in text.split('\n')) {
    final match = RegExp(r'^(\w+):\s+(\d+) kB').firstMatch(line);
    if (match == null) continue;
    sizes[match[1]!] = int.parse(match[2]!) * 1024;
  }
  return sizes;
}

/// MainActivity's platform channel (also in `storage_space.dart`).
const _platform = MethodChannel('io.github.sharon_xa.cinemakom/platform');

/// `Debug.MemoryInfo.getMemoryStats()`: its `summary.*` sizes (kB) in
/// bytes, without the prefix. Empty when the platform doesn't answer.
Future<Map<String, int>> _androidMemory() async {
  try {
    final stats = await _platform
        .invokeMapMethod<String, String>('memoryStats')
        .timeout(const Duration(seconds: 5));
    return parseAndroidMemoryStats(stats ?? const {});
  } on Object {
    return const {};
  }
}

/// Android collects Java's garbage, on a background thread (the platform
/// side of `malloc_trim` on Linux, docs/MEMORY.md §4.4). Only after the
/// player closed (`FreedMemory`) and in the memory test: otherwise Android
/// decides when to collect.
Future<void> collectJavaGarbage() async {
  try {
    await _platform
        .invokeMethod<void>('collectGarbage')
        .timeout(const Duration(seconds: 10));
  } on Object {
    return;
  }
}

Map<String, int> parseAndroidMemoryStats(Map<String, String> stats) => {
  for (final MapEntry(:key, :value) in stats.entries)
    if (key.startsWith('summary.') && int.tryParse(value) != null)
      key.substring('summary.'.length): int.parse(value) * 1024,
};

/// Memory lines in the flight recorder (docs/MEMORY.md §4.5), so the
/// Activity log on a user's device shows whether a closed video gave its
/// memory back: when the player opens, after a minute of playback, when it
/// closes, and [afterClose] later.
abstract final class MemoryLog {
  static const afterClose = Duration(seconds: 30);

  static bool _started = false;
  static Timer? _later;

  /// Lets [playerClosed] write its later line. Only `startDiagnostics`
  /// calls it: tests never do, so no timer outlives a test.
  static void start() => _started = true;

  @visibleForTesting
  static void reset() {
    _later?.cancel();
    _later = null;
    _started = false;
  }

  /// Never throws: a reading that fails is left out of the log.
  static void note(String when) {
    try {
      logEvent('memory', '$when: ${readMemoryNow().describe()}');
    } on Object {
      return;
    }
  }

  static void playerClosed() {
    note('player closed');
    _later?.cancel();
    if (!_started) return;
    _later = Timer(afterClose, () {
      _later = null;
      note('${afterClose.inSeconds} s after the player closed');
    });
  }

  /// A new video cancels the later line: it would measure the new one.
  static void playerOpened() {
    _later?.cancel();
    _later = null;
    note('player open');
  }
}
