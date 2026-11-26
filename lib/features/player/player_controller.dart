import 'dart:async';
import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart' show VideoKind;
import '../../core/network/api_providers.dart';
import '../../core/platform/platform_info.dart';
import '../../core/player/exo_player_engine.dart';
import '../../core/player/media_kit_engine.dart';
import '../../core/player/player_engine.dart';
import '../../core/storage/preferences.dart';
import '../../data/models/media_details.dart' show SkipRange;
import '../../data/models/playback_models.dart';
import '../../data/models/playback_request.dart';
import '../../data/models/watch_progress.dart';
import '../../core/diagnostics/event_log.dart';
import '../../core/diagnostics/memory.dart';
import '../../data/repositories/downloads_repository.dart';
import '../../data/repositories/library_repository.dart';
import '../../data/repositories/media_repository.dart';
import 'player_labels.dart' show formatClock;
import 'player_log.dart';
import 'player_state.dart';
import 'quality.dart';
import 'subtitles.dart';
import 'up_next.dart';

/// Makes the engine for each player session: ExoPlayer on Android (mpv
/// stuttered there, PLAYER.md §13), mpv elsewhere. Tests override it with a
/// fake.
final playerEngineFactoryProvider = Provider<PlayerEngine Function()>((ref) {
  if (isAndroid) {
    final api = ref.read(apiClientProvider);
    return () => ExoPlayerEngine(
      // Downloaded subtitles are files (Phase 6).
      loadText: (url) => url.startsWith('file:')
          ? File.fromUri(Uri.parse(url)).readAsString().then(_dropBom)
          : api.fetchText(url),
    );
  }
  return MediaKitEngine.new;
});

/// One playback session: opened by the player screen, closed with it.
final playerControllerProvider = NotifierProvider.autoDispose
    .family<PlayerController, PlayerState, PlaybackRequest>(
      PlayerController.new,
    );

/// The playback session (docs/PLAYER.md §4 and §6). The UI calls the
/// intents (`togglePlay`, `seekBy`, `selectQuality`…); the controller also
/// recovers from stream failures by itself.
class PlayerController extends Notifier<PlayerState> {
  PlayerController(this.request);

  final PlaybackRequest request;

  /// A file "completes" this close to its duration, or it was a stream
  /// failure (a failed reconnect ends the file early, PLAYER.md §6).
  static const endTolerance = Duration(seconds: 5);

  /// Watchdog: no progress for this many seconds while playing, or while
  /// opening, means the stream is stuck.
  static const stallLimitPlaying = 15;
  static const stallLimitLoading = 20;

  /// Waits before each recovery attempt. After the last, playback fails.
  static const recoveryDelays = [
    Duration.zero,
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
  ];

  /// Playing this far past a recovery resets the attempt count.
  static const recoveredAfter = Duration(seconds: 30);

  /// Progress is saved this often while playing (PLAYER.md §7.6).
  static const saveEverySeconds = 10;

  late final PlayerEngine engine;
  late final LibraryRepository _library;
  int _saveTicks = 0;

  /// Seconds played, for the memory line after a minute (MEMORY.md §4.5).
  int _playedSeconds = 0;

  /// The playhead. Kept out of [state] so only the seek bar and the clock
  /// repaint every tick.
  final position = ValueNotifier<Duration>(Duration.zero);

  /// The end of the buffered range.
  final buffered = ValueNotifier<Duration>(Duration.zero);

  /// The current lines of a plain subtitle track (empty for styled tracks,
  /// which libass draws into the frame).
  final subtitleLines = ValueNotifier<List<String>>(const []);

  final _subscriptions = <StreamSubscription<Object?>>[];
  Timer? _watchdog;

  /// Bumped by every load; async work from an older load is dropped.
  int _session = 0;
  bool _userPaused = false;
  int _stallTicks = 0;
  Duration _lastTickPosition = Duration.zero;
  int _attempt = 0;
  Duration? _recoveredAt;
  bool _recovering = false;

  /// Playing a downloaded file: no stream URLs to refresh (Phase 6).
  bool _local = false;

  /// How long a downloaded file waits for details, previews and episodes
  /// (it plays without them when offline).
  static const offlineWait = Duration(seconds: 3);

  /// Between a load starting and the new file being opened, the old file
  /// may still play: its positions must not become the new start point.
  bool _switching = false;

  /// The last position known to play, for reopening after a failure.
  Duration _resumeAt = Duration.zero;

  /// A file opening at a later point (a quality switch, a resume, a
  /// recovery): until it gets there both engines report about 0 (mpv until
  /// the file has loaded, ExoPlayer until its seek), which would show the
  /// video as restarted for a few seconds. Those positions are skipped;
  /// from [_landingFloor] on they're real, so a stream that does start
  /// from the beginning still shows it.
  bool _landing = false;
  static const _landingFloor = Duration(seconds: 2);

  /// Up next (PLAYER.md §7.7): Hide was pressed for this episode, the
  /// countdown to the next one, and the episodes started by it in a row.
  bool _upNextHidden = false;
  Timer? _countdown;
  int _autoEpisodes = 0;

  /// Skip intro (PLAYER.md §7.5): the ranges whose button was already
  /// pinned, and the timer that folds it into the controls.
  final _introsPinned = <SkipRange>{};
  Timer? _introTimer;

  /// How long Skip intro stays up by itself in each range.
  static const introPinnedFor = Duration(seconds: 8);

  /// Session choices: they win over Settings for the next episodes.
  int? _chosenHeight;
  SubtitleOption? _chosenSubtitle;

  MediaRepository get _repo => ref.read(mediaRepositoryProvider);

  @override
  PlayerState build() {
    engine = ref.read(playerEngineFactoryProvider)();
    _library = ref.read(libraryRepositoryProvider);
    _subscriptions.addAll([
      engine.position.listen(_onPosition),
      engine.buffered.listen((b) => buffered.value = b),
      engine.duration.listen(_onDuration),
      engine.aspectRatio.listen((r) {
        if (r != state.aspectRatio) state = state.copyWith(aspectRatio: r);
      }),
      engine.playing.listen(_onPlaying),
      engine.buffering.listen(_onBuffering),
      engine.completed.listen(_onCompleted),
      engine.errors.listen(_onError),
      engine.subtitleErrors.listen((_) => _onSubtitleError()),
      engine.subtitleText.listen(_onSubtitleText),
    ]);
    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    final saved = ref
        .read(preferenceStoreProvider)
        .value
        ?.getInt(PreferenceKeys.playerVolume);
    final volume = (saved ?? 100).clamp(0, 100).toDouble();
    unawaited(engine.setVolume(volume));
    // The size setting also sizes styled (libass) subtitles; the Flutter
    // layer reads it itself.
    unawaited(
      engine.setSubtitleScale(ref.read(settingsProvider).subtitleSize.scale),
    );
    ref.listen(
      settingsProvider.select((s) => s.subtitleSize),
      (_, size) => unawaited(engine.setSubtitleScale(size.scale)),
    );
    ref.onDispose(_dispose);
    // The flight recorder: every change, with where playback was.
    logEvent(
      'player',
      'open ${request.videoId}'
          '${request.start == null ? '' : ' at ${formatClock(request.start!)}'}'
          ' (${engine.runtimeType})',
    );
    MemoryLog.playerOpened();
    listenSelf((before, after) {
      final change = describePlayerChange(before, after);
      if (change != null) _log(change);
    });
    Future.microtask(
      () => _load(
        request.videoId,
        episode: request.episode,
        start: request.start,
      ),
    );
    return PlayerState.initial(request).copyWith(volume: volume);
  }

  /// A line in the log, at the playback position.
  void _log(String what) =>
      logEvent('player', '$what @ ${formatClock(position.value)}');

  void _dispose() {
    _log('close');
    _session++;
    _watchdog?.cancel();
    _countdown?.cancel();
    _introTimer?.cancel();
    for (final s in _subscriptions) {
      s.cancel();
    }
    unawaited(engine.dispose());
    MemoryLog.playerClosed();
    position.dispose();
    buffered.dispose();
    subtitleLines.dispose();
  }

  bool _isCurrent(int session) => ref.mounted && session == _session;

  // ---------------------------------------------------------------------------
  // Loading

  Future<void> _load(
    String videoId, {
    Episode? episode,
    Duration? start,
  }) async {
    final session = ++_session;
    _switching = true;
    _recovering = false;
    _attempt = 0;
    _recoveredAt = null;
    _stallTicks = 0;
    _upNextHidden = false;
    _countdown?.cancel();
    _countdown = null;
    _introTimer?.cancel();
    _introsPinned.clear();
    _resumeAt = start ?? Duration.zero;
    position.value = _resumeAt;
    buffered.value = Duration.zero;
    subtitleLines.value = const [];
    state = state.copyWith(
      videoId: videoId,
      episode: episode,
      phase: PlayerPhase.loading,
      clearError: true,
      clearDetails: true,
      clearSeekPreview: true,
      clearResumedFrom: true,
      subtitleFailed: false,
      duration: Duration.zero,
      playing: false,
      upNext: UpNext.none,
      clearIntro: true,
      introPinned: false,
      clearAspectRatio: true,
      clearLoweredFrom: true,
    );

    final repo = _repo;
    final downloads = ref.read(downloadsRepositoryProvider);
    final saved = start == null
        ? _quietly(_library.progress(videoId), null)
        : Future<WatchProgress?>.value();
    // A downloaded file plays from disk, with its saved subtitles.
    final local = await _quietly(downloads.playable(videoId), null);
    if (!_isCurrent(session)) return;
    _local = local != null;
    Future<T> online<T>(Future<T> future, T fallback) => _quietly(
      local == null ? future : future.timeout(offlineWait),
      fallback,
    );
    final streams = local == null
        ? repo.streams(videoId)
        : Future.value([
            VideoSource(
              url: Uri.file(local.path).toString(),
              name: local.quality,
              resolution: local.quality,
            ),
          ]);
    final details = online(repo.details(videoId), null);
    final tracks = local == null
        ? _quietly(repo.subtitles(videoId), const <SubtitleTrack>[])
        : Future.value(local.subtitles);
    final preview = online(repo.seekPreview(videoId), null);
    final seriesId = request.item.seriesId;
    final episodes = request.isSeries && state.episodes.isEmpty
        ? online(repo.episodes(seriesId), const <Episode>[]).then(
            // Offline: the downloaded episodes, so Next still works.
            (list) async => list.isEmpty && local != null
                ? await _quietly(
                    downloads.downloadedEpisodes(seriesId),
                    const <Episode>[],
                  )
                : list,
          )
        : Future.value(state.episodes);

    final List<VideoSource> sources;
    try {
      sources = await streams;
    } on Object catch (e) {
      // Stop the other requests' results from landing later.
      if (_isCurrent(session)) _fail(e);
      return;
    }
    final (loadedDetails, loadedTracks, loadedPreview, loadedEpisodes) = (
      await details,
      await tracks,
      await preview,
      await episodes,
    );
    final resumeAt = (await saved)?.resumeAt;
    if (!_isCurrent(session)) return;
    if (resumeAt != null) {
      _resumeAt = resumeAt;
      position.value = resumeAt;
    }
    if (sources.isEmpty) {
      _fail(PlayerFailure.unavailable);
      return;
    }

    final settings = ref.read(settingsProvider);
    final quality = pickQuality(
      sources,
      _chosenHeight ?? settings.defaultQuality.height,
    )!;
    final options = subtitleOptions([
      for (final t
          in loadedTracks.isNotEmpty || local != null
              ? loadedTracks
              : loadedDetails?.subtitles ?? const <SubtitleTrack>[])
        if (engine.supportsStyledSubtitles || !t.isStyled) t,
    ]);
    final chosen = _chosenSubtitle;
    final subtitle =
        (chosen == null ? null : carryOver(options, chosen)) ??
        pickSubtitle(options, settings.defaultSubtitle);

    state = state.copyWith(
      episode:
          episode ?? loadedEpisodes.where((e) => e.id == videoId).firstOrNull,
      episodes: loadedEpisodes,
      details: loadedDetails,
      sources: sources,
      quality: quality,
      subtitles: options,
      subtitle: subtitle,
      seekPreview: loadedPreview,
      resumedFrom: resumeAt,
    );
    await _openCurrent(session, start: _resumeAt);
  }

  /// Opens [PlayerState.quality] at [start] and sets the subtitle again
  /// (opening a file drops external subtitles).
  Future<void> _openCurrent(int session, {required Duration start}) async {
    final source = state.quality;
    if (source == null) return;
    _stallTicks = 0;
    _landing = start >= const Duration(seconds: 10);
    await engine.open(
      EngineSource(source.url, headers: ApiClient.defaultHeaders),
      start: start,
      play: !_userPaused,
    );
    if (!_isCurrent(session)) return;
    _switching = false;
    await _applySubtitle();
  }

  Future<T> _quietly<T>(Future<T> future, T fallback) async {
    try {
      return await future;
    } on Object {
      return fallback;
    }
  }

  void _fail(Object error) {
    _recovering = false;
    _switching = false;
    _landing = false;
    state = state.copyWith(phase: PlayerPhase.failed, error: error);
  }

  // ---------------------------------------------------------------------------
  // Engine events

  void _onPosition(Duration p) {
    if (_switching) return;
    if (_landing) {
      if (p < _landingFloor) return;
      _landing = false;
    }
    position.value = p;
    if (state.phase == PlayerPhase.loading && p > _resumeAt) {
      state = state.copyWith(phase: PlayerPhase.ready);
    }
    if (state.phase == PlayerPhase.ready) {
      _updateUpNext();
      _updateIntro();
      _resumeAt = p;
      final recoveredAt = _recoveredAt;
      if (recoveredAt != null && p - recoveredAt >= recoveredAfter) {
        _attempt = 0;
        _recoveredAt = null;
      }
    }
  }

  void _onDuration(Duration d) {
    if (d != state.duration) state = state.copyWith(duration: d);
  }

  void _onPlaying(bool playing) {
    if (playing != state.playing) state = state.copyWith(playing: playing);
    if (!_switching) _updateUpNext();
  }

  void _onBuffering(bool buffering) {
    if (buffering != state.buffering) {
      state = state.copyWith(buffering: buffering);
    }
    // Opened and buffered, though maybe paused. (A failed open stays
    // buffering, PLAYER.md §13.)
    if (!buffering &&
        state.phase == PlayerPhase.loading &&
        state.quality != null &&
        engine.currentDuration > Duration.zero) {
      state = state.copyWith(phase: PlayerPhase.ready);
    }
  }

  void _onCompleted(bool completed) {
    if (!completed) return;
    if (state.phase == PlayerPhase.failed || _recovering) return;
    final duration = engine.currentDuration;
    final at = position.value;
    if (duration > Duration.zero && at >= duration - endTolerance) {
      state = state.copyWith(phase: PlayerPhase.ended, playing: false);
      saveProgress();
      _updateUpNext();
    } else {
      unawaited(_recover('ended early'));
    }
  }

  void _onError(String error) {
    _log('engine error: $error');
    if (state.phase != PlayerPhase.failed &&
        engine.isDecoderError(error) &&
        _lowerQuality()) {
      return;
    }
    // On mpv, mid-play errors are often blips it gets over by itself; the
    // watchdog and the early-completion check catch the real failures.
    // ExoPlayer stops on every error, paused too, so it's reopened at once.
    final phase = state.phase;
    if ((phase == PlayerPhase.loading && state.quality != null) ||
        (phase == PlayerPhase.ready && engine.errorsStopPlayback)) {
      unawaited(_recover('engine error'));
    }
  }

  /// The device can't decode this quality (4K on some phones): the next
  /// one down, at the same place, for the rest of the session. `false` when
  /// there's none lower; then the usual recovery runs, and fails.
  bool _lowerQuality() {
    final current = state.quality;
    if (current == null) return false;
    // Streams are sorted highest first.
    final sources = state.sources;
    final i = sources.indexWhere((s) => s.url == current.url);
    if (i < 0 || i + 1 >= sources.length) return false;
    final lower = sources[i + 1];
    // selectQuality sets the new quality at once; the note needs both.
    final opening = selectQuality(lower);
    state = state.copyWith(loweredFrom: current);
    unawaited(opening);
    return true;
  }

  void _onSubtitleError() {
    subtitleLines.value = const [];
    state = state.copyWith(
      subtitle: const SubtitleOption.off(),
      subtitleFailed: true,
    );
  }

  void _onSubtitleText(List<String> lines) {
    final shown = state.subtitle.isOff || state.subtitle.isStyled
        ? const <String>[]
        : [
            for (final l in lines)
              if (l.trim().isNotEmpty) l.trim(),
          ];
    if (!listEquals(shown, subtitleLines.value)) subtitleLines.value = shown;
  }

  void _tick() {
    if (_recovering || !ref.mounted) return;
    if (state.playing && state.phase == PlayerPhase.ready) {
      if (++_playedSeconds == 60) MemoryLog.note('after 60 s of playback');
      if (++_saveTicks >= saveEverySeconds) {
        _saveTicks = 0;
        saveProgress();
      }
    }
    final phase = state.phase;
    // A file opened paused (a quality switch while paused) never moves, so
    // it isn't watched; its open errors still trigger recovery.
    final expectsProgress =
        !_userPaused &&
        ((phase == PlayerPhase.loading && state.quality != null) ||
            phase == PlayerPhase.ready);
    final p = position.value;
    if (!expectsProgress || p != _lastTickPosition) {
      _stallTicks = 0;
    } else {
      _stallTicks++;
    }
    _lastTickPosition = p;
    final limit = phase == PlayerPhase.loading
        ? stallLimitLoading
        : stallLimitPlaying;
    if (_stallTicks >= limit) {
      _stallTicks = 0;
      unawaited(_recover('stalled'));
    }
  }

  // ---------------------------------------------------------------------------
  // Skip intro (PLAYER.md §7.5)

  /// Follows the intro range under the playhead. Entering a range for the
  /// first time pins the button for [introPinnedFor].
  void _updateIntro() {
    final at = position.value;
    final range = state.phase == PlayerPhase.ready
        ? state.introRanges.where((r) => r.contains(at)).firstOrNull
        : null;
    if (range == state.intro) return;
    _introTimer?.cancel();
    final pin = range != null && _introsPinned.add(range);
    state = state.copyWith(
      intro: range,
      clearIntro: range == null,
      introPinned: pin,
    );
    if (pin) {
      _introTimer = Timer(introPinnedFor, () {
        if (ref.mounted) state = state.copyWith(introPinned: false);
      });
    }
  }

  /// Jumps to the end of the intro under the playhead (Skip intro, S).
  Future<void> skipIntro() async {
    _log('skip intro');
    final range = state.intro;
    if (range != null) await seek(range.end);
  }

  // ---------------------------------------------------------------------------
  // Up next (PLAYER.md §7.7)

  /// Shows the card from the "finished" point, runs the countdown in the
  /// last seconds while playing (or once the file ended), and hides both
  /// after a seek back.
  void _updateUpNext() {
    if (state.upNext == UpNext.stillWatching) return;
    final phase = state.phase;
    final duration = state.duration;
    final at = position.value;
    final ended = phase == PlayerPhase.ended;
    final due =
        state.nextEpisode != null &&
        !_upNextHidden &&
        (ended || (phase == PlayerPhase.ready && upNextDue(at, duration)));
    if (!due) return _setUpNext(UpNext.none);
    final counting = ended || (state.playing && countdownDue(at, duration));
    _setUpNext(counting ? UpNext.countdown : UpNext.card);
  }

  void _setUpNext(UpNext upNext) {
    if (upNext == UpNext.countdown) {
      _countdown ??= Timer(upNextCountdown, _autoAdvance);
    } else {
      _countdown?.cancel();
      _countdown = null;
    }
    if (upNext != state.upNext) state = state.copyWith(upNext: upNext);
  }

  /// The countdown ran out: the next episode, unless enough of them
  /// started by themselves that it's time to ask "Still watching?".
  void _autoAdvance() {
    _countdown = null;
    final next = state.nextEpisode;
    if (next == null || !ref.mounted) return;
    saveProgress();
    if (_autoEpisodes >= autoEpisodesBeforeAsking) {
      _log('still watching? (paused)');
      _userPaused = true;
      unawaited(engine.pause());
      _setUpNext(UpNext.stillWatching);
      return;
    }
    _autoEpisodes++;
    _log('next episode ${next.id} by itself');
    unawaited(_load(next.id, episode: next));
  }

  /// Someone is there (a tap, a key, the mouse): "Still watching?" waits
  /// for [autoEpisodesBeforeAsking] more automatic episodes.
  void noteActivity() => _autoEpisodes = 0;

  /// Play now: the next episode at once.
  Future<void> playNext() async {
    final next = state.nextEpisode;
    if (next != null) await playEpisode(next);
  }

  /// Hide: no card and no countdown for this episode.
  void hideUpNext() {
    noteActivity();
    _upNextHidden = true;
    _setUpNext(UpNext.none);
  }

  // ---------------------------------------------------------------------------
  // Recovery (PLAYER.md §6)

  Future<void> _recover(String why) async {
    if (_recovering || !ref.mounted) return;
    _log('recover ($why), attempt ${_attempt + 1}');
    if (state.phase == PlayerPhase.failed || state.phase == PlayerPhase.ended) {
      return;
    }
    if (_attempt >= recoveryDelays.length) {
      _fail(PlayerFailure.playback);
      return;
    }
    final session = _session;
    _recovering = true;
    final at = _resumeAt;
    state = state.copyWith(phase: PlayerPhase.recovering);
    await Future<void>.delayed(recoveryDelays[_attempt++]);
    if (!_isCurrent(session)) return;

    // Any open failure may be an expired URL (mpv doesn't say), so always
    // get fresh ones. A downloaded file is simply opened again.
    final List<VideoSource> sources;
    try {
      sources = _local
          ? state.sources
          : await _repo.streams(state.videoId, fresh: true);
    } on Object catch (e) {
      if (_isCurrent(session)) _fail(e);
      return;
    }
    if (!_isCurrent(session)) return;
    if (sources.isEmpty) {
      _fail(PlayerFailure.unavailable);
      return;
    }
    final quality = pickQuality(
      sources,
      state.quality?.height ?? ref.read(settingsProvider).defaultQuality.height,
    );
    state = state.copyWith(
      sources: sources,
      quality: quality,
      phase: PlayerPhase.loading,
    );
    _recoveredAt = at;
    _recovering = false;
    await _openCurrent(session, start: at);
  }

  // ---------------------------------------------------------------------------
  // Intents

  Future<void> togglePlay() => state.playing ? pause() : play();

  Future<void> play() async {
    _log('play');
    noteActivity();
    _userPaused = false;
    if (state.upNext == UpNext.stillWatching) {
      state = state.copyWith(upNext: UpNext.none);
    }
    if (state.phase == PlayerPhase.ended) {
      state = state.copyWith(phase: PlayerPhase.ready);
      await seek(Duration.zero);
    }
    await engine.play();
  }

  Future<void> pause() async {
    _log('pause');
    noteActivity();
    _userPaused = true;
    await engine.pause();
    saveProgress();
  }

  Future<void> seek(Duration to) async {
    _log('seek to ${formatClock(to)}');
    final duration = state.duration;
    final clamped = to < Duration.zero
        ? Duration.zero
        : (duration > Duration.zero && to > duration ? duration : to);
    position.value = clamped;
    _resumeAt = clamped;
    _landing = false;
    _stallTicks = 0;
    if (state.phase == PlayerPhase.ended && clamped < duration) {
      state = state.copyWith(phase: PlayerPhase.ready);
    }
    noteActivity();
    await engine.seek(clamped);
    saveProgress();
    _updateUpNext();
    _updateIntro();
  }

  /// From the beginning, after an automatic resume.
  Future<void> startOver() async {
    state = state.copyWith(clearResumedFrom: true);
    await seek(Duration.zero);
  }

  /// Hides "Resuming from …".
  void dismissResumed() => state = state.copyWith(clearResumedFrom: true);

  /// Saves how far the current video was watched. Called on a timer, on
  /// pause, seek, episode change, the end, leaving the player and the app
  /// going to the background.
  void saveProgress() {
    final duration = state.duration;
    // Nothing is known before the file opened (a resume shows its start).
    if (duration <= Duration.zero) return;
    if (state.phase == PlayerPhase.loading ||
        state.phase == PlayerPhase.failed) {
      return;
    }
    final at = state.phase == PlayerPhase.ended ? duration : position.value;
    final item = request.item;
    final episode = state.episode;
    unawaited(
      _library
          .save(
            WatchProgress(
              videoId: state.videoId,
              seriesId: request.isSeries ? item.seriesId : null,
              season: episode?.season,
              episode: episode?.episode,
              position: at,
              duration: duration,
              updatedAt: DateTime.now(),
              title: item.title,
              posterUrl: item.posterUrl,
              kind: request.isSeries ? VideoKind.series : VideoKind.movies,
            ),
          )
          .catchError((Object _) {}),
    );
  }

  Future<void> seekBy(Duration delta) => seek(position.value + delta);

  /// Sets the volume (0–100), unmutes, and remembers it for next time.
  Future<void> setVolume(double volume) async {
    noteActivity();
    final v = volume.clamp(0, 100).toDouble();
    state = state.copyWith(volume: v, muted: false);
    await engine.setVolume(v);
    await ref
        .read(preferenceStoreProvider)
        .value
        ?.setInt(PreferenceKeys.playerVolume, v.round());
  }

  /// ↑ / ↓ and the scroll wheel. From mute, it starts again at 0.
  Future<void> changeVolume(double delta) =>
      setVolume((state.muted ? 0 : state.volume) + delta);

  /// M: mute, or back to the volume before.
  Future<void> toggleMute() async {
    noteActivity();
    final muted = !state.muted;
    state = state.copyWith(muted: muted);
    await engine.setVolume(muted ? 0 : state.volume);
  }

  /// C: the next subtitle choice, Off after the last.
  Future<void> nextSubtitle() {
    final options = state.subtitles;
    final i = options.indexWhere((o) => o == state.subtitle);
    return selectSubtitle(options[(i + 1) % options.length]);
  }

  /// 0–9: jump to that tenth of the video.
  Future<void> seekToTenth(int tenth) =>
      seek(state.duration * (tenth.clamp(0, 9) / 10));

  Future<void> setSpeed(double speed) async {
    _log('speed $speed');
    noteActivity();
    state = state.copyWith(speed: speed);
    await engine.setRate(speed);
  }

  void setFit(VideoFit fit) => state = state.copyWith(fit: fit);

  /// Fit → Fill → Stretch → Fit (the fit chip). Returns the new fit.
  VideoFit cycleFit() {
    const order = VideoFit.values;
    final next = order[(order.indexOf(state.fit) + 1) % order.length];
    setFit(next);
    return next;
  }

  /// Moves the subtitle delay by [step] (the Sync buttons).
  Future<void> nudgeSubtitleDelay(Duration step) =>
      setSubtitleDelay(state.subtitleDelay + step);

  /// Switches quality at the current position, keeping play/pause, speed and
  /// the subtitle. The choice holds for the next episodes too.
  Future<void> selectQuality(VideoSource source) async {
    _log('quality ${source.label}');
    noteActivity();
    if (source.url == state.quality?.url) return;
    _chosenHeight = source.height;
    final at = position.value;
    _resumeAt = at;
    state = state.copyWith(quality: source, phase: PlayerPhase.loading);
    await _openCurrent(_session, start: at);
  }

  Future<void> selectSubtitle(SubtitleOption option) async {
    _log('subtitle ${subtitleName(option)}');
    noteActivity();
    _chosenSubtitle = option;
    state = state.copyWith(subtitle: option, subtitleFailed: false);
    await _applySubtitle();
  }

  Future<void> _applySubtitle() async {
    final option = state.subtitle;
    subtitleLines.value = const [];
    final track = option.track;
    await engine.setSubtitle(
      track == null
          ? null
          : EngineSubtitle(
              uri: track.url,
              language: track.languageCode,
              title: track.name,
              styled: track.isStyled,
            ),
    );
  }

  /// Positive values show subtitles later. Kept for the session.
  Future<void> setSubtitleDelay(Duration delay) async {
    const limit = Duration(seconds: 60);
    final clamped = delay > limit ? limit : (delay < -limit ? -limit : delay);
    state = state.copyWith(subtitleDelay: clamped);
    await engine.setSubtitleDelay(clamped);
  }

  /// After a failure: load again from where playback stopped.
  Future<void> retry() =>
      _load(state.videoId, episode: state.episode, start: _resumeAt);

  /// Switches to [episode], keeping quality, subtitle choice and speed. It
  /// resumes where that episode was left, if it was.
  Future<void> playEpisode(Episode episode) {
    _log('episode ${episode.id} (S${episode.season}E${episode.episode})');
    noteActivity();
    _userPaused = false;
    saveProgress();
    return _load(episode.id, episode: episode);
  }
}

String _dropBom(String text) =>
    text.startsWith('\uFEFF') ? text.substring(1) : text;
