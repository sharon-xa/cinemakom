// The app's own libmpv must win over any system copy or LIBMPV_LIBRARY_PATH
// (docs/PACKAGING.md §3–§4): two libmpv in one process abort when a video
// opens.

import 'package:cinemakom/core/player/media_kit_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Linux: the libmpv next to the app is used', () {
    expect(
      bundledLibmpv(
        executable: '/home/u/.local/lib/cinemakom/usr/lib/cinemakom/cinemakom',
        isWindowsOverride: false,
        exists: (path) => true,
      ),
      '/home/u/.local/lib/cinemakom/usr/lib/cinemakom/lib/libmpv.so.2',
    );
  });

  test(
    'Linux: without one (a development build), the system libmpv is used',
    () {
      expect(
        bundledLibmpv(
          executable: '/src/build/linux/x64/debug/bundle/cinemakom',
          isWindowsOverride: false,
          exists: (path) => false,
        ),
        isNull,
      );
    },
  );

  test('Windows: the libmpv-2.dll next to cinemakom.exe is used', () {
    expect(
      bundledLibmpv(
        executable:
            r'C:\Users\u\AppData\Local\Programs\Cinemakom\cinemakom.exe',
        isWindowsOverride: true,
        exists: (path) => true,
      ),
      r'C:\Users\u\AppData\Local\Programs\Cinemakom\libmpv-2.dll',
    );
  });

  test('Windows: returns null if no libmpv-2.dll is beside the executable', () {
    expect(
      bundledLibmpv(
        executable: r'C:\src\cinemakom.exe',
        isWindowsOverride: true,
        exists: (path) => false,
      ),
      isNull,
    );
  });
}
