// Giving glibc's freed memory back after the player closes
// (docs/MEMORY.md M2, fix 1).
import 'dart:io';

import 'package:cinemakom/core/diagnostics/event_log.dart';
import 'package:cinemakom/core/platform/native_heap.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(NativeHeap.cancel);

  test('supported on Linux (glibc) only', () {
    expect(NativeHeap.supported, Platform.isLinux);
  });

  test('the trim waits until mpv is destroyed, and checks no player opened '
      'meanwhile', () {
    fakeAsync((async) {
      var asked = 0;
      NativeHeap.trimSoon(
        stillIdle: () {
          asked++;
          return false; // A player opened: no trim.
        },
      );
      async.elapse(NativeHeap.delay - const Duration(milliseconds: 1));
      expect(asked, 0);
      async.elapse(const Duration(milliseconds: 1));
      expect(asked, Platform.isLinux ? 1 : 0);
    });
  });

  test('a new player cancels the waiting trim', () {
    fakeAsync((async) {
      var asked = 0;
      NativeHeap.trimSoon(stillIdle: () => ++asked > 0);
      NativeHeap.cancel();
      async.elapse(NativeHeap.delay * 2);
      expect(asked, 0);
    });
  });

  test('a second close restarts the wait', () {
    fakeAsync((async) {
      var asked = 0;
      bool idle() {
        asked++;
        return false;
      }

      NativeHeap.trimSoon(stillIdle: idle);
      async.elapse(NativeHeap.delay ~/ 2);
      NativeHeap.trimSoon(stillIdle: idle);
      async.elapse(NativeHeap.delay ~/ 2);
      expect(asked, 0);
      async.elapse(NativeHeap.delay ~/ 2);
      expect(asked, Platform.isLinux ? 1 : 0);
    });
  });

  test('trimming runs malloc_trim off the main isolate and logs what it gave '
      'back', () async {
    await NativeHeap.trim();
    final lines = [
      for (final e in EventLog.instance.recent)
        if (e.tag == 'memory') e.message,
    ];
    if (Platform.isLinux) {
      expect(lines.single, startsWith('gave back '));
      expect(lines.single, contains('rss '));
    } else {
      expect(lines, isEmpty);
    }
  });
}
