import 'dart:async';

import 'package:cinemakom/core/player/player_engine.dart';
import 'package:flutter/widgets.dart';

/// A [PlayerEngine] driven by the test: it records every call, and the test
/// pushes events with the `emit…` methods. Events are delivered
/// synchronously.
class FakeEngine implements PlayerEngine {
  FakeEngine({
    this.supportsStyledSubtitles = true,
    this.errorsStopPlayback = false,
  });

  @override
  final bool supportsStyledSubtitles;
  @override
  final bool errorsStopPlayback;

  @override
  bool isDecoderError(String error) => error.startsWith('decoder:');

  final opened = <({EngineSource source, Duration start, bool play})>[];
  final subtitles = <EngineSubtitle?>[];
  final seeks = <Duration>[];
  double rate = 1;
  Duration subtitleDelay = Duration.zero;
  double subtitleScale = 1;
  bool isPlaying = false;
  bool disposed = false;

  final _position = StreamController<Duration>.broadcast(sync: true);
  final _duration = StreamController<Duration>.broadcast(sync: true);
  final _aspectRatio = StreamController<double>.broadcast(sync: true);
  final _buffered = StreamController<Duration>.broadcast(sync: true);
  final _playing = StreamController<bool>.broadcast(sync: true);
  final _buffering = StreamController<bool>.broadcast(sync: true);
  final _completed = StreamController<bool>.broadcast(sync: true);
  final _errors = StreamController<String>.broadcast(sync: true);
  final _subtitleErrors = StreamController<String>.broadcast(sync: true);
  final _subtitleText = StreamController<List<String>>.broadcast(sync: true);

  @override
  Duration currentPosition = Duration.zero;
  @override
  Duration currentDuration = Duration.zero;

  /// Plays the opened file: duration known, buffered, position at [at].
  void emitReady({Duration duration = const Duration(hours: 2), Duration? at}) {
    emitDuration(duration);
    emitBuffering(false);
    emitPosition(at ?? opened.last.start + const Duration(seconds: 1));
  }

  void emitPosition(Duration p) {
    currentPosition = p;
    _position.add(p);
  }

  void emitDuration(Duration d) {
    currentDuration = d;
    _duration.add(d);
  }

  void emitAspectRatio(double r) => _aspectRatio.add(r);
  void emitBuffering(bool b) => _buffering.add(b);
  void emitCompleted() => _completed.add(true);
  void emitError(String e) => _errors.add(e);
  void emitSubtitleError() => _subtitleErrors.add('Can not open external file');
  void emitSubtitleText(List<String> lines) => _subtitleText.add(lines);

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
  Future<void> open(
    EngineSource source, {
    Duration start = Duration.zero,
    bool play = true,
  }) async {
    opened.add((source: source, start: start, play: play));
    currentDuration = Duration.zero;
    currentPosition = start;
    _completed.add(false);
    _buffering.add(true);
    _setPlaying(play);
  }

  void _setPlaying(bool p) {
    isPlaying = p;
    _playing.add(p);
  }

  @override
  Future<void> play() async => _setPlaying(true);
  @override
  Future<void> pause() async => _setPlaying(false);
  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    emitPosition(position);
  }

  @override
  Future<void> setRate(double rate) async => this.rate = rate;
  double volume = 100;
  @override
  Future<void> setVolume(double volume) async => this.volume = volume;
  @override
  Future<void> setSubtitle(EngineSubtitle? track) async => subtitles.add(track);
  @override
  Future<void> setSubtitleDelay(Duration delay) async => subtitleDelay = delay;
  @override
  Future<void> setSubtitleScale(double scale) async => subtitleScale = scale;

  @override
  Widget buildVideo({BoxFit fit = BoxFit.contain}) => const SizedBox.expand();

  @override
  Future<Map<String, int>> frameStats() async => const {};

  /// The last [setVideoAlone], for the player screen's tests.
  bool videoAlone = true;

  @override
  Future<void> setVideoAlone(bool alone) async => videoAlone = alone;

  @override
  Future<void> dispose() async => disposed = true;
}
