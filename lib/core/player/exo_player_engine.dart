import 'dart:async';
import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import 'player_engine.dart';

/// [PlayerEngine] on Android's ExoPlayer (through video_player). The only
/// file that imports video_player.
///
/// Why Android doesn't use mpv: media_kit copies every decoded frame back
/// to memory and draws it into a Flutter texture, and 4K stuttered on a
/// real phone even with frame dropping off (PLAYER.md §13). ExoPlayer
/// decodes in hardware into a texture with no copy back to memory.
///
/// Texture, not the SurfaceView platform view: with Flutter's platform
/// views the SurfaceView is drawn above every Flutter widget, so the
/// controls only showed on the letterbox bars.
///
/// Subtitles: plain SRT/VTT files are downloaded with [loadText] (the
/// shared headers), parsed here and sent as text for the Flutter layer.
/// Styled ASS needs libass, so it isn't offered ([supportsStyledSubtitles]).
class ExoPlayerEngine implements PlayerEngine {
  ExoPlayerEngine({required this.loadText});

  /// Downloads a subtitle file (`ApiClient.fetchText`).
  final Future<String> Function(String url) loadText;

  final _controller = ValueNotifier<VideoPlayerController?>(null);

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _aspectRatio = StreamController<double>.broadcast();
  final _buffered = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _errors = StreamController<String>.broadcast();
  final _subtitleErrors = StreamController<String>.broadcast();
  final _subtitleText = StreamController<List<String>>.broadcast();

  double _rate = 1;
  double _volume = 100;
  Duration _subtitleDelay = Duration.zero;
  List<Caption> _captions = const [];
  List<String> _shownLines = const [];

  /// Whether playback was asked for and not paused: what [playing]
  /// reports. ExoPlayer's own isPlaying is false whenever it buffers, and
  /// on a weak connection it flipped many times a second; that's
  /// [buffering] here, as on mpv (PLAYER.md §6).
  bool _wantsPlay = false;
  bool _reportedPlaying = false;

  void _reportPlaying() {
    if (_disposed || _wantsPlay == _reportedPlaying) return;
    _reportedPlaying = _wantsPlay;
    _playing.add(_wantsPlay);
  }

  /// The last value without an error.
  VideoPlayerValue? _last;
  String? _lastError;

  /// Bumped by every [open] and [setSubtitle]; older async work is dropped.
  int _openId = 0;
  int _subtitleId = 0;
  bool _disposed = false;

  @override
  bool get supportsStyledSubtitles => false;

  /// ExoPlayer retries a failed read itself, then stops with an error.
  @override
  bool get errorsStopPlayback => true;

  /// ExoPlayer names the failing renderer, e.g. "MediaCodecVideoRenderer
  /// error, … format_supported=NO_EXCEEDS_CAPABILITIES" for a 4K file the
  /// phone can't decode.
  @override
  bool isDecoderError(String error) =>
      error.contains('MediaCodecVideoRenderer') ||
      error.contains('DecoderInitializationException') ||
      error.contains('Decoder init failed');

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
  Duration get currentPosition => _last?.position ?? Duration.zero;
  @override
  Duration get currentDuration => _last?.duration ?? Duration.zero;

  @override
  Future<void> open(
    EngineSource source, {
    Duration start = Duration.zero,
    bool play = true,
  }) async {
    if (_disposed) return;
    final id = ++_openId;
    // Overtaken by a newer open, or the player closed, at any await below:
    // whatever this open made is closed again and nothing more is reported.
    bool stale() => id != _openId || _disposed;
    await _release();
    if (stale()) return;
    _last = null;
    _lastError = null;
    _completed.add(false);
    _buffering.add(true);
    _wantsPlay = false;
    _reportedPlaying = false;
    _playing.add(false);
    // External subtitles belong to the old file (PlayerEngine.open).
    _subtitleId++;
    _setCaptions(const []);

    // Audio focus is AudioFocus's (audio_session): a second request from
    // ExoPlayer would take focus from it (PLAYER.md §9.1).
    final options = VideoPlayerOptions(mixWithOthers: true);
    final uri = Uri.parse(source.uri);
    // A downloaded file (Phase 6) plays from disk.
    final controller = uri.isScheme('file')
        ? VideoPlayerController.file(
            File.fromUri(uri),
            viewType: VideoViewType.textureView,
            videoPlayerOptions: options,
          )
        : VideoPlayerController.networkUrl(
            uri,
            httpHeaders: source.headers,
            viewType: VideoViewType.textureView,
            videoPlayerOptions: options,
          );
    try {
      await controller.initialize();
      if (!stale()) await controller.setPlaybackSpeed(_rate);
      if (!stale()) await controller.setVolume(_volume / 100);
      if (!stale() && start > Duration.zero) await controller.seekTo(start);
    } on Object catch (e) {
      await controller.dispose();
      // A failed open stays "buffering", like mpv (PLAYER.md §13); the
      // controller sees the error and recovers.
      if (!stale()) _errors.add('$e');
      return;
    }
    if (stale()) {
      // Never shown: an ExoPlayer nobody holds would play on behind.
      await controller.dispose();
      return;
    }
    controller.addListener(() => _onValue(controller));
    _controller.value = controller;
    _onValue(controller);
    if (play) {
      _wantsPlay = true;
      _reportPlaying();
      await controller.play();
    }
  }

  void _onValue(VideoPlayerController controller) {
    if (!identical(controller, _controller.value) || _disposed) return;
    final v = controller.value;
    final error = v.errorDescription;
    if (error != null) {
      // ExoPlayer stopped. video_player resets the value (position and
      // duration 0, not playing), so keep the last good one: the controller
      // reopens the file where it was.
      if (error != _lastError) {
        _lastError = error;
        _errors.add(error);
      }
      return;
    }
    final last = _last;
    _last = v;
    if (last == null || v.position != last.position) {
      _position.add(v.position);
      _updateSubtitle(v.position);
    }
    if (last == null || v.duration != last.duration) _duration.add(v.duration);
    if ((last == null || v.size != last.size) &&
        v.size.width > 0 &&
        v.size.height > 0) {
      _aspectRatio.add(v.size.aspectRatio);
    }
    final end = _bufferedEnd(v);
    if (last == null || end != _bufferedEnd(last)) _buffered.add(end);
    // The end of the file stops it (ExoPlayer pauses there).
    if (v.isCompleted && (last == null || !last.isCompleted)) {
      _wantsPlay = false;
    }
    _reportPlaying();
    if (last == null || v.isBuffering != last.isBuffering) {
      _buffering.add(v.isBuffering);
    }
    if (last == null || v.isCompleted != last.isCompleted) {
      _completed.add(v.isCompleted);
    }
  }

  /// The end of the buffered range under the playhead.
  static Duration _bufferedEnd(VideoPlayerValue v) {
    var end = Duration.zero;
    for (final r in v.buffered) {
      if (r.start <= v.position && r.end > end) end = r.end;
    }
    return end;
  }

  @override
  Future<void> play() async {
    final controller = _controller.value;
    if (_disposed || controller == null) return;
    _wantsPlay = true;
    _reportPlaying();
    await controller.play();
  }

  @override
  Future<void> pause() async {
    final controller = _controller.value;
    if (_disposed || controller == null) return;
    _wantsPlay = false;
    _reportPlaying();
    await controller.pause();
  }

  @override
  Future<void> seek(Duration position) async =>
      _controller.value?.seekTo(position);

  @override
  Future<void> setRate(double rate) async {
    _rate = rate;
    await _controller.value?.setPlaybackSpeed(rate);
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0, 100).toDouble();
    await _controller.value?.setVolume(_volume / 100);
  }

  @override
  Future<void> setSubtitle(EngineSubtitle? track) async {
    if (_disposed) return;
    final id = ++_subtitleId;
    _setCaptions(const []);
    if (track == null) return;
    if (track.styled) {
      _subtitleErrors.add('Styled subtitles need libass: ${track.uri}');
      return;
    }
    try {
      final text = await loadText(track.uri);
      if (id != _subtitleId || _disposed) return;
      final ClosedCaptionFile file = text.trimLeft().startsWith('WEBVTT')
          ? WebVTTCaptionFile(text)
          : SubRipCaptionFile(text);
      final captions = file.captions;
      if (captions.isEmpty) throw const FormatException('No captions');
      _setCaptions(captions);
    } on Object catch (e) {
      if (id == _subtitleId && !_disposed) _subtitleErrors.add('$e');
    }
  }

  void _setCaptions(List<Caption> captions) {
    _captions = captions;
    _updateSubtitle(currentPosition);
  }

  void _updateSubtitle(Duration at) {
    final t = at - _subtitleDelay;
    final lines = <String>[
      for (final c in _captions)
        if (c.start <= t && t < c.end)
          for (final line in plainCaptionText(c.text).split('\n'))
            if (line.trim().isNotEmpty) line,
    ];
    if (listEquals(lines, _shownLines)) return;
    _shownLines = lines;
    if (!_disposed) _subtitleText.add(lines);
  }

  @override
  Future<void> setSubtitleDelay(Duration delay) async {
    _subtitleDelay = delay;
    _updateSubtitle(currentPosition);
  }

  /// The Flutter layer sizes plain subtitles itself.
  @override
  Future<void> setSubtitleScale(double scale) async {}

  @override
  Widget buildVideo({BoxFit fit = BoxFit.contain}) =>
      ValueListenableBuilder<VideoPlayerController?>(
        valueListenable: _controller,
        builder: (context, controller, _) {
          if (controller == null) return const SizedBox.expand();
          final size = controller.value.size;
          return SizedBox.expand(
            child: FittedBox(
              fit: fit,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: size.width > 0 ? size.width : 16,
                height: size.height > 0 ? size.height : 9,
                // A new file gets a new view.
                child: VideoPlayer(controller, key: ObjectKey(controller)),
              ),
            ),
          );
        },
      );

  Future<void> _release() async {
    final old = _controller.value;
    if (old == null) return;
    _controller.value = null;
    await old.dispose();
  }

  /// video_player doesn't report ExoPlayer's dropped frames; the TV's frame
  /// pacing is measured from outside (`tool/tv_cadence.sh`).
  @override
  Future<Map<String, int>> frameStats() async => const {};

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _openId++;
    await _release();
    _controller.dispose();
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
}

/// [text] without the markup SubRip files carry, which video_player keeps:
/// SSA override blocks (`{\an8}`, `{\i1}`) and HTML-style tags (`<i>`,
/// `<font color=…>`). mpv drops them itself.
@visibleForTesting
String plainCaptionText(String text) => text
    .replaceAll(RegExp(r'\{\\[^}]*\}'), '')
    .replaceAll(
      RegExp(r'</?(?:i|b|u|s|font)\b[^>]*>', caseSensitive: false),
      '',
    );
