import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/event_log.dart';
import '../platform/app_dirs.dart';
import '../platform/freed_memory.dart';
import '../platform/platform_info.dart';
import 'player_engine.dart';
import 'subtitle_fonts.dart';

/// Starts media_kit, once, before the first player (`main`).
///
/// Desktop builds carry their own libmpv (`lib/libmpv.so.2` in the Linux
/// AppImage, `libmpv-2.dll` next to `cinemakom.exe` on Windows;
/// docs/PACKAGING.md §3–§4), and media_kit must use that one. Left to itself
/// it honors `LIBMPV_LIBRARY_PATH` and then system library names, which can
/// load a second libmpv alongside the one `media_kit_video` linked and abort
/// as a video opens.
///
/// This covers media_kit's players only: media_kit_video's decoder check
/// calls `NativeLibrary.ensureInitialized()` again with no path, which
/// forgets this one. Linux AppRun and Windows `main.cpp` also set
/// `LIBMPV_LIBRARY_PATH` to the bundled library to cover that check.
void initMediaKit() => MediaKit.ensureInitialized(libmpv: bundledLibmpv());

/// The bundled libmpv next to the app (`<app>/lib/libmpv.so.2` on Linux,
/// `<app>\libmpv-2.dll` on Windows), else `null` (Android, or a Linux
/// development build on the system's libmpv).
@visibleForTesting
String? bundledLibmpv({
  String? executable,
  bool? isWindowsOverride,
  bool Function(String path)? exists,
}) {
  final win = isWindowsOverride ?? (executable == null && Platform.isWindows);
  if (executable == null && !Platform.isLinux && !win) return null;
  final exe = executable ?? Platform.resolvedExecutable;
  final path = win
      ? p.windows.join(p.windows.dirname(exe), 'libmpv-2.dll')
      : p.posix.join(p.posix.dirname(exe), 'lib', 'libmpv.so.2');
  return (exists ?? (f) => File(f).existsSync())(path) ? path : null;
}

/// [PlayerEngine] on media_kit (libmpv). The only file that imports
/// media_kit. Options and their reasons: docs/PLAYER.md §5 and §13.
class MediaKitEngine implements PlayerEngine {
  MediaKitEngine({bool? recreatePerFile})
    : recreatePerFile =
          recreatePerFile ?? defaultTargetPlatform == TargetPlatform.android {
    FreedMemory.engineOpened();
  }

  /// Create a new native player for every [open]. On the Android emulator a
  /// second `open()` on the same player never brought the picture back,
  /// while a new player per file worked (PLAYER.md §13). Until a real phone
  /// shows the same player can be reused, Android recreates it.
  final bool recreatePerFile;

  /// mpv's counters, by the names [frameStats] uses.
  static const _frameCounters = {
    'dropped': 'frame-drop-count',
    'decoder_dropped': 'decoder-frame-drop-count',
    'late': 'vo-delayed-frame-count',
  };

  @override
  Future<Map<String, int>> frameStats() async {
    final player = _player;
    if (player == null || _disposed) return const {};
    final native = player.platform! as NativePlayer;
    final stats = <String, int>{};
    for (final MapEntry(:key, :value) in _frameCounters.entries) {
      try {
        if (int.tryParse(await native.getProperty(value)) case final n?) {
          stats[key] = n;
        }
      } on Object {
        continue;
      }
    }
    return stats;
  }

  static int get _bufferBytes => (isDesktop ? 192 : 64) * 1024 * 1024;

  static Map<String, String> get _options => {
    'ytdl': 'no',
    'network-timeout': '20',
    'demuxer-readahead-secs': '20',
    'cache-secs': isDesktop ? '60' : '30',
    // mpv's frame dropping misjudges 4K on phones: it dropped about 1 frame
    // in 40 that wasn't late, a visible stutter. With it off: 0 dropped,
    // 0 late, full frame rate (PLAYER.md §13).
    if (!isDesktop) 'framedrop': 'no',
  };

  /// Directory for mpv's disk cache on desktop. Without `demuxer-cache-dir`,
  /// Windows libmpv fails with "Failed to create file cache." and keeps the
  /// buffer in RAM; on Linux this also keeps the cache out of tmpfs `/tmp`.
  static String? _diskCacheDir() {
    final base = AppDirs.current?.cache;
    final path = base != null
        ? p.join(base, 'mpv-cache')
        : p.join(Directory.systemTemp.path, 'cinemakom-mpv-cache');
    try {
      Directory(path).createSync(recursive: true);
      return path;
    } on Object {
      return null;
    }
  }

  Player? _player;

  /// Native players made and not yet disposed, across engines: a test
  /// checks none is left behind (one nobody holds would play on).
  @visibleForTesting
  static int get livePlayers => _livePlayers;
  static int _livePlayers = 0;
  final _video = ValueNotifier<VideoController?>(null);
  final _subscriptions = <StreamSubscription<Object?>>[];

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _aspectRatio = StreamController<double>.broadcast();
  int? _width;
  int? _height;
  final _buffered = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _errors = StreamController<String>.broadcast();
  final _subtitleErrors = StreamController<String>.broadcast();
  final _subtitleText = StreamController<List<String>>.broadcast();

  double _rate = 1;
  double _volume = 100;
  double _subtitleScale = 1;
  Duration _subtitleDelay = Duration.zero;
  bool _disposed = false;

  @override
  bool get supportsStyledSubtitles => true;

  /// mpv reports blips it gets over by itself (PLAYER.md §13).
  @override
  bool get errorsStopPlayback => false;

  /// mpv falls back to software decoding by itself (`hwdec=auto`), and its
  /// error text isn't parsed (PLAYER.md §13).
  @override
  bool isDecoderError(String error) => false;

  @override
  Stream<Duration> get position => _position.stream;
  @override
  Stream<Duration> get duration => _duration.stream;
  @override
  Stream<double> get aspectRatio => _aspectRatio.stream;
  @override
  Stream<Duration> get buffered => _buffered.stream;
  @override
  Stream<bool> get playing => _playing.stream;
  @override
  Stream<bool> get buffering => _buffering.stream;
  @override
  Stream<bool> get completed => _completed.stream;
  @override
  Stream<String> get errors => _errors.stream;
  @override
  Stream<String> get subtitleErrors => _subtitleErrors.stream;
  @override
  Stream<List<String>> get subtitleText => _subtitleText.stream;

  @override
  Duration get currentPosition => _player?.state.position ?? Duration.zero;
  @override
  Duration get currentDuration => _player?.state.duration ?? Duration.zero;

  /// The native player for the next file, or `null` when the engine was
  /// closed meanwhile (then nothing new is made, and one being set up is
  /// left to [dispose], which already closed it).
  Future<Player?> _ensurePlayer({required bool fresh}) async {
    final existing = _player;
    if (existing != null && !fresh) return existing;
    if (existing != null) await _release(existing);
    if (_disposed) return null;

    final player = Player(
      configuration: PlayerConfiguration(
        bufferSize: _bufferBytes,
        libass: true,
        libassAndroidFont: isAndroid ? libassFontAsset : null,
        libassAndroidFontName: isAndroid ? libassFontFamily : null,
      ),
    );
    _livePlayers++;
    _player = player;
    bool gone() => _disposed || !identical(_player, player);
    final native = player.platform! as NativePlayer;
    try {
      for (final MapEntry(:key, :value) in _options.entries) {
        await native.setProperty(key, value);
      }
      // The disk cache fails on Android ("Failed to create file cache") and on
      // Windows unless `demuxer-cache-dir` points to an existing folder.
      final cacheDir = isDesktop ? _diskCacheDir() : null;
      if (cacheDir != null) {
        await native.setProperty('demuxer-cache-dir', cacheDir);
        await native.setProperty('cache-on-disk', 'yes');
      } else {
        await native.setProperty('cache-on-disk', 'no');
      }
      if (!isAndroid) {
        final fonts = await libassFontsDir();
        if (fonts != null) {
          await native.setProperty('sub-fonts-dir', fonts);
          await native.setProperty('sub-font', libassFontFamily);
        }
      }
      // Settings the user picked survive a new native player.
      await player.setRate(_rate);
      await player.setVolume(_volume);
      await native.setProperty('sub-scale', '$_subtitleScale');
      await native.setProperty('sub-delay', _seconds(_subtitleDelay));
    } on Object {
      // A player closed while it was set up refuses every call.
      if (gone()) return null;
      rethrow;
    }
    if (gone()) return null;

    final s = player.stream;
    _subscriptions.addAll([
      s.position.listen(_position.add),
      s.duration.listen(_duration.add),
      s.buffer.listen(_buffered.add),
      s.playing.listen(_playing.add),
      s.buffering.listen(_buffering.add),
      s.completed.listen(_completed.add),
      s.error.listen(_onError),
      s.subtitle.listen(_subtitleText.add),
      s.width.listen((w) => _onSize(w, _height)),
      s.height.listen((h) => _onSize(_width, h)),
    ]);
    _video.value = VideoController(player);
    return player;
  }

  String? _subtitleUri;

  void _onError(String text) {
    final sub = _subtitleUri;
    // mpv: "Can not open external file <url>." for a subtitle it can't load.
    if (text.contains('external file') || (sub != null && text.contains(sub))) {
      _subtitleErrors.add(text);
    } else {
      _errors.add(text);
    }
  }

  Future<void> _release(Player player) async {
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    _video.value = null;
    if (identical(_player, player)) _player = null;
    _livePlayers--;
    await player.dispose();
  }

  /// Bumped by every [open]: an older open stops at its next step.
  int _openId = 0;

  /// Opens run one after another, so two never set up or release native
  /// players at once; one overtaken before its turn is skipped.
  Future<void> _opening = Future<void>.value();

  /// Never throws: a file that can't open is reported on [errors], and one
  /// overtaken by a newer open, or by [dispose], just stops.
  @override
  Future<void> open(
    EngineSource source, {
    Duration start = Duration.zero,
    bool play = true,
  }) {
    if (_disposed) return Future<void>.value();
    final id = ++_openId;
    return _opening = _opening.then(
      (_) => _open(id, source, start: start, play: play),
    );
  }

  Future<void> _open(
    int id,
    EngineSource source, {
    required Duration start,
    required bool play,
  }) async {
    bool stale() => id != _openId || _disposed;
    if (stale()) return;
    try {
      final player = await _ensurePlayer(
        fresh: recreatePerFile && _player != null,
      );
      if (player == null || stale()) return;
      await player.open(
        Media(source.uri, httpHeaders: source.headers, start: start),
        play: play,
      );
    } on Object catch (e) {
      if (!stale()) _errors.add('$e');
    }
  }

  /// Runs [action] on the native player, if there is one. One closed under
  /// it (the player screen leaving) refuses the call: that's no error.
  Future<void> _onPlayer(Future<void> Function(Player player) action) async {
    final player = _player;
    if (player == null) return;
    try {
      await action(player);
    } on Object {
      if (_disposed || !identical(_player, player)) return;
      rethrow;
    }
  }

  @override
  Future<void> play() => _onPlayer((p) => p.play());

  @override
  Future<void> pause() => _onPlayer((p) => p.pause());

  @override
  Future<void> seek(Duration position) => _onPlayer((p) => p.seek(position));

  @override
  Future<void> setRate(double rate) {
    _rate = rate;
    return _onPlayer((p) => p.setRate(rate));
  }

  @override
  Future<void> setVolume(double volume) {
    _volume = volume.clamp(0, 100).toDouble();
    return _onPlayer((p) => p.setVolume(_volume));
  }

  @override
  Future<void> setSubtitle(EngineSubtitle? track) => _onPlayer((player) async {
    _subtitleUri = track?.uri;
    if (track == null) {
      await player.setSubtitleTrack(SubtitleTrack.no());
      return;
    }
    // Plain tracks: mpv still parses them and sends the text, but Flutter
    // draws it. Styled tracks: libass draws them into the frame.
    await (player.platform! as NativePlayer).setProperty(
      'sub-visibility',
      track.styled ? 'yes' : 'no',
    );
    await player.setSubtitleTrack(
      SubtitleTrack.uri(
        track.uri,
        title: track.title,
        language: track.language,
      ),
    );
  });

  @override
  Future<void> setSubtitleDelay(Duration delay) {
    _subtitleDelay = delay;
    return _onPlayer(
      (p) => (p.platform! as NativePlayer).setProperty(
        'sub-delay',
        _seconds(delay),
      ),
    );
  }

  @override
  Future<void> setSubtitleScale(double scale) {
    _subtitleScale = scale;
    return _onPlayer(
      (p) => (p.platform! as NativePlayer).setProperty('sub-scale', '$scale'),
    );
  }

  @override
  Widget buildVideo({BoxFit fit = BoxFit.contain}) =>
      ValueListenableBuilder<VideoController?>(
        valueListenable: _video,
        builder: (context, controller, _) => controller == null
            ? const SizedBox.expand()
            : Video(
                // A new native player gets a new texture.
                key: ObjectKey(controller),
                controller: controller,
                fit: fit,
                fill: const Color(0x00000000),
                controls: NoVideoControls,
                // Plain subtitles are drawn by the player screen.
                subtitleViewConfiguration: const SubtitleViewConfiguration(
                  visible: false,
                ),
              ),
      );

  void _onSize(int? width, int? height) {
    _width = width;
    _height = height;
    if (width != null && height != null && width > 0 && height > 0) {
      _aspectRatio.add(width / height);
      if (_decoderLoggedFor != _openId) {
        _decoderLoggedFor = _openId;
        unawaited(_logDecoder(width, height));
      }
    }
  }

  /// The open for which [_logDecoder] ran: once per file.
  int _decoderLoggedFor = -1;

  /// The decoder mpv picked for the file, in the flight recorder: hardware
  /// (`vaapi`, `nvdec`, `d3d11va`…), a copy back to memory (`…-copy`), or
  /// software (`no`). A 4K file in software is the first suspect when
  /// playback or the controls aren't smooth.
  Future<void> _logDecoder(int width, int height) async {
    final player = _player;
    if (player == null || _disposed) return;
    final native = player.platform! as NativePlayer;
    Future<String> read(String name) async {
      try {
        return await native.getProperty(name);
      } on Object {
        return '?';
      }
    }

    // The decoder settles a moment after the size is known.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (_disposed || !identical(_player, player)) return;
    final hwdec = await read('hwdec-current');
    final codec = await read('video-format');
    logEvent(
      'player',
      'decoder ${hwdec.isEmpty ? 'no' : hwdec} · $codec $width×$height',
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final player = _player;
    if (player != null) await _release(player);
    // Linux: glibc keeps what mpv freed; give it back once no player is
    // open (docs/MEMORY.md M2, fix 1).
    FreedMemory.engineClosed(played: player != null);
    _video.dispose();
    for (final c in [
      _position,
      _duration,
      _aspectRatio,
      _buffered,
      _playing,
      _buffering,
      _completed,
      _errors,
      _subtitleErrors,
      _subtitleText,
    ]) {
      await c.close();
    }
  }

  static String _seconds(Duration d) => (d.inMilliseconds / 1000).toString();
}
