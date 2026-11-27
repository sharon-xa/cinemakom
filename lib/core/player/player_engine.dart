import 'package:flutter/widgets.dart';

/// What to play: a URL (with the shared headers) or, from Phase 6, a local
/// file path.
class EngineSource {
  const EngineSource(this.uri, {this.headers = const {}});

  final String uri;
  final Map<String, String> headers;

  @override
  String toString() => 'EngineSource(${Uri.tryParse(uri)?.path ?? uri})';
}

/// An external subtitle file. [styled] ASS tracks are drawn by libass inside
/// the frame; plain ones are drawn by Flutter from [PlayerEngine.subtitleText]
/// (docs/PLAYER.md §7.2).
class EngineSubtitle {
  const EngineSubtitle({
    required this.uri,
    required this.language,
    this.title,
    this.styled = false,
  });

  final String uri;
  final String language;
  final String? title;
  final bool styled;
}

/// The video player, without any UI. `MediaKitEngine` (mpv) runs on desktop,
/// `ExoPlayerEngine` on Android; tests use a fake. Only the engine
/// implementations know about their packages.
///
/// The streams are broadcast streams that survive [open], even when the
/// implementation recreates its native player for a new file.
abstract interface class PlayerEngine {
  /// Whether styled (ASS) subtitles can be drawn. When not, the player
  /// doesn't offer them.
  bool get supportsStyledSubtitles;

  /// Whether every error on [errors] means playback stopped for good, so
  /// the file must be reopened. True for ExoPlayer; mpv also reports blips
  /// it gets over by itself.
  bool get errorsStopPlayback;

  /// Whether [error] (from [errors]) says the device couldn't decode the
  /// file, so a lower quality may play (PLAYER.md §6).
  bool isDecoderError(String error);

  Stream<Duration> get position;
  Stream<Duration> get duration;

  /// The picture's width ÷ height, once the file shows it.
  Stream<double> get aspectRatio;

  /// The end of the buffered range.
  Stream<Duration> get buffered;

  /// Whether playback was asked for and not paused: not whether frames are
  /// moving right now. A stall is [buffering] with [playing] still true
  /// (ExoPlayer's own isPlaying drops at every stall, PLAYER.md §6).
  Stream<bool> get playing;
  Stream<bool> get buffering;

  /// `true` when the file ended. A failed reconnect also ends the file, so
  /// check the position before treating it as finished (PLAYER.md §6).
  Stream<bool> get completed;

  /// Errors from the native player, as text. They are not reliable enough to
  /// tell an expired URL from a network failure (PLAYER.md §13). Unless
  /// [errorsStopPlayback], some come from blips the player recovers from by
  /// itself, so only act on them while a file is opening.
  Stream<String> get errors;

  /// An external subtitle file couldn't be loaded.
  Stream<String> get subtitleErrors;

  /// The current lines of a plain subtitle track, for the Flutter layer.
  Stream<List<String>> get subtitleText;

  Duration get currentPosition;
  Duration get currentDuration;

  /// Opens [source] at [start]. Playback starts unless [play] is false.
  /// External subtitles are dropped: set them again after opening.
  Future<void> open(
    EngineSource source, {
    Duration start = Duration.zero,
    bool play = true,
  });

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);

  /// 1.0 is normal speed.
  Future<void> setRate(double rate);

  /// 0–100.
  Future<void> setVolume(double volume);

  /// `null` turns subtitles off.
  Future<void> setSubtitle(EngineSubtitle? track);

  /// Positive values show subtitles later.
  Future<void> setSubtitleDelay(Duration delay);

  /// Size of styled (libass) subtitles; 1.0 is the file's own size.
  Future<void> setSubtitleScale(double scale);

  /// The video surface, scaled with [fit]. Rebuilds itself if the native
  /// player is recreated.
  Widget buildVideo({BoxFit fit = BoxFit.contain});

  /// Frame counters since the file opened, for the performance checks
  /// (docs/MEMORY.md §2.1): `dropped` (frames the player skipped to keep
  /// up), `decoder_dropped` (the decoder fell behind) and `late` (shown
  /// after their time). Empty where the engine can't tell (ExoPlayer
  /// through video_player).
  Future<Map<String, int>> frameStats();

  /// Whether nothing but the video is on screen: no controls, menus or
  /// notes over it. On Linux mpv's texture then waits for each frame's
  /// display time before Flutter draws it, which keeps the video's timing
  /// exact on a VRR or high-refresh screen but holds the UI at ~25 fps;
  /// with something over the video it doesn't wait, so the UI gets its
  /// 60 fps and the video shows on Flutter's 60 Hz ticks (docs/PLAYER.md
  /// §14). The default is alone. Nothing elsewhere.
  Future<void> setVideoAlone(bool alone);

  Future<void> dispose();
}
