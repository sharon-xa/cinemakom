// Giving freed memory back after the player closes
// (docs/MEMORY.md M2, fixes 1 and 2).
import 'dart:io';

import 'package:cinemakom/core/diagnostics/event_log.dart';
import 'package:cinemakom/core/platform/freed_memory.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(FreedMemory.reset);

  List<String> lines() => [
    for (final e in EventLog.instance.recent)
      if (e.tag == 'memory') e.message,
  ];

  // The host running the tests: Linux (glibc) gives memory back, Windows
  // has no way to.
  final gives = Platform.isLinux ? 1 : 0;

  test('supported on Linux (glibc) and Android', () {
    expect(FreedMemory.supported, Platform.isLinux || Platform.isAndroid);
  });

  test('the next player, made before it fetched what to play, cancels it', () {
    fakeAsync((async) {
      FreedMemory.engineOpened();
      FreedMemory.engineClosed(played: true);
      async.elapse(FreedMemory.delay ~/ 2);
      FreedMemory.engineOpened(); // The next video's screen opens.
      async.elapse(FreedMemory.delay * 2);
      expect(lines(), isEmpty);
    });
  });

  test('nothing while another player is still open', () {
    fakeAsync((async) {
      FreedMemory.engineOpened();
      FreedMemory.engineOpened();
      FreedMemory.engineClosed(played: true);
      async.elapse(FreedMemory.delay * 2);
      expect(lines(), isEmpty);
    });
  });

  test('nothing after a player that never played', () {
    fakeAsync((async) {
      FreedMemory.engineOpened();
      FreedMemory.engineClosed(played: false);
      async.elapse(FreedMemory.delay * 2);
      expect(lines(), isEmpty);
    });
  });

  test('giving back runs off the main isolate and logs what it gave '
      'back', () async {
    await FreedMemory.giveBack();
    expect(lines(), hasLength(gives));
    if (gives == 1) {
      expect(lines().single, startsWith('gave back '));
      expect(lines().single, contains('rss '));
    }
  });

  test('memory is given back once mpv is destroyed, after the last player '
      'closed', () async {
    FreedMemory.engineOpened();
    FreedMemory.engineClosed(played: true);
    await Future<void>.delayed(
      FreedMemory.delay + const Duration(milliseconds: 500),
    );
    expect(lines(), hasLength(gives));
  }, timeout: const Timeout(Duration(seconds: 30)));
}
