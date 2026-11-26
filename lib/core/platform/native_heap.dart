import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../diagnostics/event_log.dart';

/// Gives glibc's freed memory back to the system after the player closes
/// (Linux; docs/MEMORY.md M2, fix 1).
///
/// mpv and FFmpeg free most of what a 4K video used when the player closes,
/// but glibc keeps it in its per-thread arenas for reuse, so RSS stays
/// ~250 MB above where it was (findings 2 and 9). `malloc_trim(0)` hands
/// that back. It runs only once no player is open, never while a video
/// plays, and in a background isolate: it can take tens of milliseconds and
/// holds the allocator's locks meanwhile, and no frame should wait for it.
abstract final class NativeHeap {
  /// After the last player is disposed. media_kit destroys mpv 5 s after
  /// `dispose()` (media_kit 1.2.6, `real.dart`), and mpv's threads free
  /// their memory as they end, so trimming any sooner misses most of it.
  static const delay = Duration(seconds: 10);

  static Timer? _pending;

  /// Whether this platform can trim: glibc's `malloc_trim`, looked up once.
  static final bool supported = () {
    if (!Platform.isLinux) return false;
    try {
      ffi.DynamicLibrary.process().lookup<ffi.Void>('malloc_trim');
      return true;
    } on Object {
      // Not glibc (musl, say): nothing to trim with.
      return false;
    }
  }();

  /// Trims [delay] from now, unless [cancel] runs first (a new player).
  /// [stillIdle] is asked again then: a player opened meanwhile skips it.
  static void trimSoon({required bool Function() stillIdle}) {
    if (!supported) return;
    _pending?.cancel();
    _pending = Timer(delay, () {
      _pending = null;
      if (stillIdle()) unawaited(trim());
    });
  }

  /// A player is opening: a trim still waiting would run during it.
  static void cancel() {
    _pending?.cancel();
    _pending = null;
  }

  /// `malloc_trim(0)` in a background isolate, with the RSS before and
  /// after in the flight recorder. Never throws.
  @visibleForTesting
  static Future<void> trim() async {
    if (!supported) return;
    try {
      final before = ProcessInfo.currentRss;
      final watch = Stopwatch()..start();
      await Isolate.run(_mallocTrim);
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
