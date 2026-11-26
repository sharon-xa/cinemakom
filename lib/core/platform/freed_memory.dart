import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../diagnostics/event_log.dart';
import '../diagnostics/memory.dart';

/// Gives the memory a closed video freed back to the system
/// (docs/MEMORY.md M2, fixes 1 and 2). Both engines free what they used
/// when the player closes, but it stays with the app until something hands
/// it back:
///
/// - **Linux:** glibc keeps what mpv and FFmpeg freed in its per-thread
///   arenas for reuse (findings 2, 9, 17). `malloc_trim(0)` returns it.
/// - **Android:** ExoPlayer's ~150 MB buffer is let go but waits for a Java
///   garbage collection, and after closing the app hardly allocates, so ART
///   doesn't collect (finding 11). One collection frees it all.
///
/// It runs only once no player is open, never while a video plays, and
/// never on the UI thread: a background isolate on Linux, a background
/// thread on Android (MainActivity's `collectGarbage`).
abstract final class FreedMemory {
  /// After the last player is disposed. media_kit destroys mpv 5 s after
  /// `dispose()` (media_kit 1.2.6, `real.dart`), and mpv's threads free
  /// their memory as they end, so any sooner misses most of it.
  static const delay = Duration(seconds: 10);

  static Timer? _pending;

  /// Player engines made and not yet disposed. One is made as the player
  /// screen opens, before it has fetched what to play, so a give-back still
  /// waiting is cancelled then, not only once a file opens.
  static int _engines = 0;

  /// The memory test turns it off for some rounds, to compare with and
  /// without in one install (`MEMORY_AB=give_back`).
  @visibleForTesting
  static bool debugEnabled = true;

  /// Whether this platform has a way: glibc's `malloc_trim` (looked up
  /// once), or Android's garbage collector.
  static final bool supported = () {
    if (Platform.isAndroid) return true;
    if (!Platform.isLinux) return false;
    try {
      ffi.DynamicLibrary.process().lookup<ffi.Void>('malloc_trim');
      return true;
    } on Object {
      // Not glibc (musl, say): nothing to trim with.
      return false;
    }
  }();

  /// A player engine was made: a give-back still waiting would run while
  /// it opens or plays.
  static void engineOpened() {
    _engines++;
    _pending?.cancel();
    _pending = null;
  }

  /// A player engine was disposed. When it played something ([played]) and
  /// no other engine is left, memory is given back [delay] from now, unless
  /// another engine is made first.
  static void engineClosed({required bool played}) {
    if (_engines > 0) _engines--;
    if (!supported || !played || _engines > 0 || !debugEnabled) return;
    _pending?.cancel();
    _pending = Timer(delay, () {
      _pending = null;
      if (_engines == 0) unawaited(giveBack());
    });
  }

  @visibleForTesting
  static void reset() {
    _pending?.cancel();
    _pending = null;
    _engines = 0;
    debugEnabled = true;
  }

  /// Now, with the RSS before and after in the flight recorder. Never
  /// throws.
  @visibleForTesting
  static Future<void> giveBack() async {
    if (!supported) return;
    try {
      final before = ProcessInfo.currentRss;
      final watch = Stopwatch()..start();
      if (Platform.isAndroid) {
        await collectJavaGarbage();
      } else {
        await Isolate.run(_mallocTrim);
      }
      final after = ProcessInfo.currentRss;
      logEvent(
        'memory',
        'gave back ${_mb(before - after)} MB after the player closed '
            '(rss ${_mb(before)} → ${_mb(after)} MB, '
            '${watch.elapsedMilliseconds} ms)',
      );
    } on Object catch (e) {
      logEvent('memory', "couldn't give memory back: $e");
    }
  }
}

int _mb(int bytes) => (bytes / (1 << 20)).round();

/// In the background isolate: its own lookup, as FFI functions don't cross
/// isolates.
void _mallocTrim() {
  ffi.DynamicLibrary.process()
      .lookupFunction<ffi.Int Function(ffi.Size), int Function(int)>(
        'malloc_trim',
      )(0);
}
