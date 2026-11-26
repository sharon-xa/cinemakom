import 'dart:async';

import 'package:flutter/gestures.dart'
    show PointerScrollEvent, kDoubleTapTimeout;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../app/l10n/app_localizations.dart';
import '../../app/theme/marquee_colors.dart';
import '../../app/theme/marquee_text.dart';
import '../../app/widgets/bulb_loader.dart';
import '../../app/widgets/error_view.dart';
import '../../app/widgets/media_image.dart' show networkImagesProvider;
import '../../core/network/api_exception.dart';
import '../../core/platform/full_screen.dart';
import '../../core/platform/orientation.dart';
import '../../core/platform/platform_info.dart';
import '../../core/player/audio_focus.dart';
import '../../core/storage/preferences.dart';
import '../../data/models/playback_models.dart';
import '../../data/models/playback_request.dart';
import 'player_controller.dart';
import 'player_labels.dart';
import 'player_state.dart';
import 'quality.dart';
import 'widgets/chip_menus.dart';
import 'up_next.dart';
import 'widgets/controls_overlay.dart';
import 'widgets/episodes_panel.dart';
import 'widgets/gesture_layer.dart';
import 'widgets/seek_preview_frame.dart';
import 'widgets/skip_intro_button.dart';
import 'widgets/subtitle_layer.dart';
import 'widgets/up_next_card.dart';

/// The full-screen player (docs/PLAYER.md §8). It owns what only the screen
/// knows about: whether the controls show, the menus, orientation, the
/// wakelock. Playback itself is [PlayerController].
class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key, required this.request});

  final PlaybackRequest request;

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  static const _hideAfter = Duration(seconds: 3);
  static const _bufferingDelay = Duration(milliseconds: 300);
  static const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
  static const _toastFor = Duration(milliseconds: 1200);
  static const _resumedFor = Duration(seconds: 5);

  bool _visible = true;
  bool _menuOpen = false;
  bool _scrubbing = false;
  bool _showBuffering = false;

  /// The controls lock (phones): touches do nothing but show [_Unlock].
  bool _locked = false;
  bool _unlockShown = false;
  Timer? _unlockTimer;

  /// Calls, other apps and unplugged headphones pause playback (phones).
  AudioFocus? _audio;

  /// Desktop full screen, and whether the window was already full screen
  /// when the player opened (it's left that way on exit).
  late final FullScreen _window;
  late final bool _wasFullScreen;
  bool _fullScreen = false;

  /// The last click on the video, to spot a double click.
  DateTime? _lastClick;
  Timer? _hideTimer;
  Timer? _bufferingTimer;
  Timer? _toastTimer;
  Timer? _resumedTimer;

  /// A short note in the middle of the screen ("Fill" after the fit chip).
  ({IconData icon, String label})? _toast;

  PlayerController get _controller =>
      ref.read(playerControllerProvider(widget.request).notifier);

  /// Kept for dispose, where `ref` can't be used.
  late final PlayerController _session;
  late final AppLifecycleListener _lifecycle;

  /// The browsing orientation to return to (Settings can't change while
  /// the player is open).
  late final ScreenRotation _rotation;
  PlayerState get _state => ref.read(playerControllerProvider(widget.request));

  @override
  void initState() {
    super.initState();
    _session = _controller;
    _window = ref.read(fullScreenProvider);
    _wasFullScreen = isDesktop && _window.isOn;
    _fullScreen = _wasFullScreen;
    _rotation = ref.read(settingsProvider).screenRotation;
    // Progress survives the app being killed in the background.
    _lifecycle = AppLifecycleListener(
      onInactive: () => _session.saveProgress(),
      onHide: () => _session.saveProgress(),
    );
    if (isMobile) {
      _audio = AudioFocus(
        onPause: () => _session.pause(),
        onResume: () => _session.play(),
      );
      unawaited(_audio!.start());
      // Either landscape side; Android only flips between them when
      // the device's auto-rotate allows it.
      setPlayerOrientation();
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  @override
  void dispose() {
    _session.saveProgress();
    if (_fullScreen != _wasFullScreen) _window.set(_wasFullScreen);
    _lifecycle.dispose();
    _hideTimer?.cancel();
    _bufferingTimer?.cancel();
    _toastTimer?.cancel();
    _resumedTimer?.cancel();
    _unlockTimer?.cancel();
    unawaited(_audio?.dispose());
    unawaited(_wakelock(on: false));
    if (isMobile) {
      setBrowseOrientation(_rotation);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Controls visibility (PLAYER.md §8)

  void _show() {
    if (!_visible) setState(() => _visible = true);
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_state.playing || _menuOpen || _scrubbing) return;
    _hideTimer = Timer(_hideAfter, () {
      if (mounted && _state.playing && !_menuOpen && !_scrubbing) {
        setState(() => _visible = false);
      }
    });
  }

  /// A tap, a key or the mouse: someone is watching (PLAYER.md §7.7).
  void _input() {
    _controller.noteActivity();
    _show();
  }

  /// A tap on the video: hides the controls (paused too), or brings them back.
  void _toggle() {
    _controller.noteActivity();
    if (_visible) {
      _hide();
    } else {
      _show();
    }
  }

  void _hide() {
    _hideTimer?.cancel();
    if (_visible) setState(() => _visible = false);
  }

  /// Opens a menu; the controls stay up while it's open. Closing it without
  /// a pick (a tap on the video, back, a swipe down) hides them too.
  Future<T?> _menu<T>(
    Rect anchor,
    WidgetBuilder builder, {
    double width = 340,
  }) => _open(
    () => showPlayerMenu<T>(
      context,
      anchor: anchor,
      builder: builder,
      width: width,
    ),
  );

  /// Keeps the controls up while [show]'s menu or panel is open.
  Future<T?> _open<T>(Future<T?> Function() show) async {
    _controller.noteActivity();
    _menuOpen = true;
    _show();
    final picked = await show();
    _menuOpen = false;
    if (!mounted) return picked;
    if (picked == null) {
      _hide();
    } else {
      _scheduleHide();
    }
    return picked;
  }

  void _back() {
    if (context.canPop()) context.pop();
  }

  // ---------------------------------------------------------------------------
  // Desktop: full screen, mouse, keys (PLAYER.md §9.2)

  void _toggleFullScreen() {
    final on = !_fullScreen;
    _window.set(on);
    setState(() => _fullScreen = on);
    _show();
  }

  /// Esc: out of full screen first, then out of the player.
  void _escape() => _fullScreen ? _toggleFullScreen() : _back();

  /// A click on the video plays or pauses at once. A double click is two
  /// clicks, so playback comes back as it was, and the window goes full
  /// screen.
  void _click() {
    _input();
    final now = DateTime.now();
    final last = _lastClick;
    _lastClick = now;
    unawaited(_controller.togglePlay());
    if (last != null && now.difference(last) < kDoubleTapTimeout) {
      _lastClick = null;
      _toggleFullScreen();
    }
  }

  Future<void> _volumeBy(double delta) async {
    await _controller.changeVolume(delta);
    _showVolume();
  }

  void _showVolume() {
    if (!mounted) return;
    final s = _state;
    final silent = s.muted || s.volume == 0;
    _showToast(
      silent ? Icons.volume_off_outlined : Icons.volume_up_outlined,
      s.muted
          ? AppLocalizations.of(context).playerMuted
          : '${s.volume.round()}%',
    );
  }

  /// [ and ]: one step through the speed menu's choices.
  Future<void> _speedStep(int step) async {
    final i = _speeds.indexOf(_state.speed);
    final next = _speeds[((i < 0 ? 2 : i) + step).clamp(0, _speeds.length - 1)];
    await _controller.setSpeed(next);
    _showToast(Icons.speed, speedLabel(next));
  }

  // ---------------------------------------------------------------------------
  // Controls lock (PLAYER.md §9.1)

  void _lock() {
    _hideTimer?.cancel();
    setState(() {
      _locked = true;
      _visible = false;
    });
    _showUnlock();
  }

  /// A tap while locked: the unlock button, for 3 s.
  void _showUnlock() {
    _unlockTimer?.cancel();
    setState(() => _unlockShown = true);
    _unlockTimer = Timer(_hideAfter, () {
      if (mounted) setState(() => _unlockShown = false);
    });
  }

  void _unlock() {
    if (!_locked) return;
    _unlockTimer?.cancel();
    setState(() {
      _locked = false;
      _unlockShown = false;
    });
    _show();
  }

  Future<void> _episodesPanel() async {
    final picked = await _open(
      () => showEpisodesPanel(
        context,
        seriesId: widget.request.item.seriesId,
        current: _state.episode,
      ),
    );
    if (picked != null && picked.id != _state.videoId) {
      await _controller.playEpisode(picked);
    }
  }

  void _showToast(IconData icon, String label) {
    _toastTimer?.cancel();
    setState(() => _toast = (icon: icon, label: label));
    _toastTimer = Timer(_toastFor, () {
      if (mounted) setState(() => _toast = null);
    });
  }

  // ---------------------------------------------------------------------------
  // Menus (PLAYER.md §8)

  void _subtitleMenu(Rect anchor) => _menu<bool>(
    anchor,
    (_) => SubtitleMenu(request: widget.request),
    width: SubtitleMenu.popoverWidth,
  );

  Future<void> _qualityMenu(AppLocalizations l10n, Rect anchor) async {
    final current = _state.quality;
    if (current == null) return;
    final picked = await _menu<VideoSource>(
      anchor,
      (_) => ChoiceMenu(
        title: l10n.playerQuality,
        selected: current,
        choices: [
          for (final s in _state.sources)
            MenuChoice(
              s,
              s.label,
              caption: s.height == 2160 ? l10n.quality4kCaption : null,
            ),
        ],
      ),
    );
    if (picked != null) await _controller.selectQuality(picked);
  }

  Future<void> _speedMenu(AppLocalizations l10n, Rect anchor) async {
    final picked = await _menu<double>(
      anchor,
      (_) => ChoiceMenu(
        title: l10n.playerSpeed,
        selected: _state.speed,
        choices: [for (final s in _speeds) MenuChoice(s, speedLabel(s))],
      ),
    );
    if (picked != null) await _controller.setSpeed(picked);
  }

  Future<void> _fitMenu(AppLocalizations l10n, Rect anchor) async {
    final picked = await _menu<VideoFit>(
      anchor,
      (_) => ChoiceMenu(
        title: l10n.playerScreenFit,
        selected: _state.fit,
        choices: [
          for (final f in VideoFit.values) MenuChoice(f, fitLabel(l10n, f)),
        ],
      ),
    );
    if (picked != null) _controller.setFit(picked);
  }

  void _cycleFit(AppLocalizations l10n) {
    final fit = _controller.cycleFit();
    _showToast(fitIcon(fit), fitLabel(l10n, fit));
    _show();
  }

  /// Narrow screens: one menu with each chip and its value; a pick opens
  /// that chip's menu in the same place.
  Future<void> _moreMenu(AppLocalizations l10n, Rect anchor) async {
    final state = _state;
    final quality = state.quality;
    final picked = await _menu<_ChipMenu>(
      anchor,
      (_) => ChoiceMenu(
        title: l10n.playerMore,
        choices: [
          if (state.subtitles.length > 1)
            MenuChoice(
              _ChipMenu.subtitles,
              l10n.playerSubtitles,
              trailing: subtitleLabel(l10n, state.subtitle),
            ),
          if (quality != null && state.sources.length > 1)
            MenuChoice(
              _ChipMenu.quality,
              l10n.playerQuality,
              trailing: qualityChipLabel(quality),
            ),
          MenuChoice(
            _ChipMenu.speed,
            l10n.playerSpeed,
            trailing: speedLabel(state.speed),
          ),
          MenuChoice(
            _ChipMenu.fit,
            l10n.playerScreenFit,
            trailing: fitLabel(l10n, state.fit),
          ),
        ],
      ),
    );
    if (!mounted || picked == null) return;
    switch (picked) {
      case _ChipMenu.subtitles:
        _subtitleMenu(anchor);
      case _ChipMenu.quality:
        await _qualityMenu(l10n, anchor);
      case _ChipMenu.speed:
        await _speedMenu(l10n, anchor);
      case _ChipMenu.fit:
        await _fitMenu(l10n, anchor);
    }
  }

  // ---------------------------------------------------------------------------

  void _listen(AppLocalizations l10n) {
    final provider = playerControllerProvider(widget.request);
    ref
      ..listen(provider.select((s) => s.playing), (_, playing) {
        unawaited(_wakelock(on: playing));
        _audio?.playing(playing);
        if (playing) {
          _scheduleHide();
        } else {
          _show();
        }
      })
      ..listen(provider.select((s) => s.buffering), (_, buffering) {
        _bufferingTimer?.cancel();
        if (!buffering) {
          if (_showBuffering) setState(() => _showBuffering = false);
          return;
        }
        // Short stalls don't flash the loader.
        _bufferingTimer = Timer(_bufferingDelay, () {
          if (mounted && _state.buffering) {
            setState(() => _showBuffering = true);
          }
        });
      })
      ..listen(provider.select((s) => s.upNext), (_, upNext) {
        // "Still watching?" needs an answer.
        if (upNext == UpNext.stillWatching) _unlock();
      })
      ..listen(provider.select((s) => s.seekPreview), (_, preview) {
        if (preview != null) _prefetch(preview);
      })
      ..listen(provider.select((s) => s.loweredFrom), (_, from) {
        final to = _state.quality;
        if (from == null || to == null) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n.playerQualityLowered(
                qualityChipLabel(from),
                qualityChipLabel(to),
              ),
            ),
          ),
        );
      })
      ..listen(provider.select((s) => s.subtitleFailed), (_, failed) {
        if (!failed) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l10n.playerSubtitlesFailed)));
      })
      ..listen(provider.select((s) => s.phase), (_, phase) {
        if (phase == PlayerPhase.failed || phase == PlayerPhase.ended) {
          // Try again and the end need the controls.
          _unlock();
          _show();
        }
        // "Resuming from …" stays 5 s once the video plays.
        if (phase == PlayerPhase.ready && _state.resumedFrom != null) {
          _resumedTimer?.cancel();
          _resumedTimer = Timer(_resumedFor, () {
            if (mounted) _controller.dismissResumed();
          });
        }
      });
  }

  /// The sprite sheet under the playhead and the next one, so the first
  /// scrub shows frames at once (PLAYER.md §7.8).
  void _prefetch(SeekPreview preview) {
    if (!ref.read(networkImagesProvider)) return;
    final urls = preview.sheetUrls;
    final here = preview.frameAt(_controller.position.value)?.url;
    final from = here == null ? 0 : urls.indexOf(here).clamp(0, urls.length);
    for (final url in urls.skip(from).take(2)) {
      unawaited(
        precacheImage(seekSheetImage(url), context, onError: (_, _) {}),
      );
    }
  }

  /// The keys of PLAYER.md §9.2, the same in both languages (including when
  /// the OS keyboard layout is Arabic).
  Map<ShortcutActivator, VoidCallback> get _shortcuts {
    VoidCallback key(void Function() action) => () {
      _input();
      action();
    };
    void seekBy(int seconds) =>
        unawaited(_controller.seekBy(Duration(seconds: seconds)));
    return {
      const SingleActivator(LogicalKeyboardKey.space): key(_togglePlay),
      const _KeyActivator(LogicalKeyboardKey.keyK, PhysicalKeyboardKey.keyK):
          key(_togglePlay),
      const SingleActivator(LogicalKeyboardKey.arrowLeft): key(
        () => seekBy(-10),
      ),
      const SingleActivator(LogicalKeyboardKey.arrowRight): key(
        () => seekBy(10),
      ),
      const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): key(
        () => seekBy(-60),
      ),
      const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): key(
        () => seekBy(60),
      ),
      const SingleActivator(LogicalKeyboardKey.arrowUp): key(
        () => _volumeBy(5),
      ),
      const SingleActivator(LogicalKeyboardKey.arrowDown): key(
        () => _volumeBy(-5),
      ),
      const _KeyActivator(
        LogicalKeyboardKey.keyM,
        PhysicalKeyboardKey.keyM,
      ): key(() async {
        await _controller.toggleMute();
        _showVolume();
      }),
      if (isDesktop)
        const _KeyActivator(LogicalKeyboardKey.keyF, PhysicalKeyboardKey.keyF):
            key(_toggleFullScreen),
      const _KeyActivator(LogicalKeyboardKey.keyC, PhysicalKeyboardKey.keyC):
          key(() => unawaited(_controller.nextSubtitle())),
      const _KeyActivator(
        LogicalKeyboardKey.bracketLeft,
        PhysicalKeyboardKey.bracketLeft,
      ): key(
        () => _speedStep(-1),
      ),
      const _KeyActivator(
        LogicalKeyboardKey.bracketRight,
        PhysicalKeyboardKey.bracketRight,
      ): key(
        () => _speedStep(1),
      ),
      for (final (i, (logical, physical)) in _digits.indexed)
        _KeyActivator(logical, physical): key(
          () => unawaited(_controller.seekToTenth(i)),
        ),
      const _KeyActivator(LogicalKeyboardKey.keyS, PhysicalKeyboardKey.keyS):
          key(() => unawaited(_controller.skipIntro())),
      const _KeyActivator(LogicalKeyboardKey.keyN, PhysicalKeyboardKey.keyN):
          key(() => unawaited(_controller.playNext())),
      const SingleActivator(LogicalKeyboardKey.escape): _escape,
    };
  }

  void _togglePlay() => unawaited(_controller.togglePlay());

  static const _digits = [
    (LogicalKeyboardKey.digit0, PhysicalKeyboardKey.digit0),
    (LogicalKeyboardKey.digit1, PhysicalKeyboardKey.digit1),
    (LogicalKeyboardKey.digit2, PhysicalKeyboardKey.digit2),
    (LogicalKeyboardKey.digit3, PhysicalKeyboardKey.digit3),
    (LogicalKeyboardKey.digit4, PhysicalKeyboardKey.digit4),
    (LogicalKeyboardKey.digit5, PhysicalKeyboardKey.digit5),
    (LogicalKeyboardKey.digit6, PhysicalKeyboardKey.digit6),
    (LogicalKeyboardKey.digit7, PhysicalKeyboardKey.digit7),
    (LogicalKeyboardKey.digit8, PhysicalKeyboardKey.digit8),
    (LogicalKeyboardKey.digit9, PhysicalKeyboardKey.digit9),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(playerControllerProvider(widget.request));
    final subtitleScale = ref.watch(
      settingsProvider.select((s) => s.subtitleSize.scale),
    );
    final controller = _controller;
    final toast = _toast;
    _listen(l10n);

    final phase = state.phase;
    final busy =
        phase == PlayerPhase.loading ||
        phase == PlayerPhase.recovering ||
        (_showBuffering && state.buffering);
    final failed = phase == PlayerPhase.failed;

    // Back unlocks first.
    return PopScope(
      canPop: !_locked,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _unlock();
      },
      child: Scaffold(
        backgroundColor: MarqueeColors.screen,
        body: CallbackShortcuts(
          bindings: _shortcuts,
          child: Focus(
            autofocus: true,
            child: MouseRegion(
              cursor: _visible ? MouseCursor.defer : SystemMouseCursors.none,
              onHover: (_) => _input(),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  controller.engine.buildVideo(
                    fit: switch (state.fit) {
                      VideoFit.fit => BoxFit.contain,
                      VideoFit.fill => BoxFit.cover,
                      VideoFit.stretch => BoxFit.fill,
                    },
                  ),
                  SubtitleLayer(
                    lines: controller.subtitleLines,
                    lifted: _visible,
                    scale: subtitleScale,
                  ),
                  // Wraps the controls: the scrim takes every hit, so a tap
                  // detector under it would never fire. Buttons inside still
                  // win their own taps. Phones get the touch gestures.
                  _gestures(
                    l10n,
                    state,
                    IgnorePointer(
                      ignoring: !_visible || _locked,
                      child: AnimatedOpacity(
                        opacity: _visible && !_locked ? 1 : 0,
                        duration: controlsFade,
                        curve: Curves.easeOut,
                        child: ControlsOverlay(
                          state: state,
                          controller: controller,
                          busy: busy || failed,
                          onBack: _back,
                          onSubtitles: _subtitleMenu,
                          onQuality: (anchor) => _qualityMenu(l10n, anchor),
                          onSpeed: (anchor) => _speedMenu(l10n, anchor),
                          onFit: () => _cycleFit(l10n),
                          onMore: (anchor) => _moreMenu(l10n, anchor),
                          onEpisodes: widget.request.isSeries
                              ? _episodesPanel
                              : null,
                          trailing: [
                            if (isMobile)
                              _ChipIcon(
                                icon: Icons.lock_outline,
                                tooltip: l10n.playerLock,
                                onPressed: _lock,
                              ),
                            if (isDesktop)
                              _ChipIcon(
                                icon: _fullScreen
                                    ? Icons.fullscreen_exit
                                    : Icons.fullscreen,
                                tooltip: _fullScreen
                                    ? l10n.playerExitFullScreen
                                    : l10n.playerFullScreen,
                                onPressed: _toggleFullScreen,
                              ),
                          ],
                          onScrub: (at) {
                            _scrubbing = at != null;
                            if (_scrubbing) {
                              _hideTimer?.cancel();
                            } else {
                              _scheduleHide();
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                  if (busy && !failed)
                    IgnorePointer(
                      child: _Busy(
                        label: phase == PlayerPhase.recovering
                            ? l10n.playerReconnecting
                            : null,
                      ),
                    ),
                  if (failed)
                    _Failure(
                      error: state.error,
                      onRetry: controller.retry,
                      onBack: _back,
                    ),
                  if (state.resumedFrom case final from?
                      when phase == PlayerPhase.ready && !_locked)
                    _Resumed(from: from, onStartOver: controller.startOver),
                  if (state.nextEpisode case final next?
                      when state.upNext != UpNext.none && !failed && !_locked)
                    UpNextCard(
                      next: next,
                      upNext: state.upNext,
                      onPlayNow: controller.playNext,
                      onHide: controller.hideUpNext,
                    )
                  else if (state.intro != null &&
                      phase == PlayerPhase.ready &&
                      !failed &&
                      !_locked)
                    SkipIntroButton(
                      visible: state.introPinned || _visible,
                      onPressed: () {
                        _controller.noteActivity();
                        _controller.skipIntro();
                      },
                    ),
                  if (toast != null && !busy && !failed)
                    IgnorePointer(
                      child: _Toast(icon: toast.icon, label: toast.label),
                    ),
                  if (_locked && _unlockShown) _Unlock(onPressed: _unlock),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Phones: taps, double taps and swipes over the controls.
  /// Desktop: a tap shows or hides them (mouse and keys come in M8).
  Widget _gestures(AppLocalizations l10n, PlayerState state, Widget controls) =>
      isMobile
      ? GestureLayer(
          controller: _controller,
          state: state,
          locked: _locked,
          onTap: _toggle,
          onLockedTap: _showUnlock,
          child: controls,
        )
      : Listener(
          // The scroll wheel sets the volume.
          onPointerSignal: (e) {
            if (e is PointerScrollEvent && e.scrollDelta.dy != 0) {
              unawaited(_volumeBy(e.scrollDelta.dy < 0 ? 5 : -5));
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _click,
            child: controls,
          ),
        );
}

enum _ChipMenu { subtitles, quality, speed, fit }

/// A round icon button in the top bar, styled like the chips.
class _ChipIcon extends StatelessWidget {
  const _ChipIcon({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.only(start: MarqueeSpace.s),
    child: IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      style: withFocusRing(
        IconButton.styleFrom(
          backgroundColor: MarqueeColors.booth,
          foregroundColor: MarqueeColors.cream,
          side: const BorderSide(color: MarqueeColors.velvet),
          fixedSize: const Size.square(44),
        ),
      ),
    ),
  );
}

/// While locked: a small Unlock pill at the top end, shown for 3 s after a
/// tap.
class _Unlock extends StatelessWidget {
  const _Unlock({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return SafeArea(
      child: Align(
        alignment: AlignmentDirectional.topEnd,
        child: Padding(
          padding: EdgeInsetsDirectional.only(
            top: MarqueeSpace.m,
            end: width >= 600 ? MarqueeSpace.xxxl : MarqueeSpace.l,
          ),
          child: TextButton.icon(
            onPressed: onPressed,
            icon: const Icon(Icons.lock_open_outlined, size: 20),
            label: Text(AppLocalizations.of(context).playerUnlock),
            style: withFocusRing(
              TextButton.styleFrom(
                backgroundColor: MarqueeColors.booth,
                foregroundColor: MarqueeColors.cream,
                side: const BorderSide(color: MarqueeColors.velvet),
                shape: const StadiumBorder(),
                minimumSize: const Size(44, 44),
                padding: const EdgeInsetsDirectional.symmetric(
                  horizontal: MarqueeSpace.l,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Keeps the screen on while playing. A missing plugin (tests, odd
/// platforms) just means no wakelock.
Future<void> _wakelock({required bool on}) async {
  try {
    await (on ? WakelockPlus.enable() : WakelockPlus.disable());
  } on Object {
    // Not available here.
  }
}

class _Busy extends StatelessWidget {
  const _Busy({this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    final label = this.label;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          BulbLoader(semanticLabel: AppLocalizations.of(context).loading),
          if (label != null) ...[
            const SizedBox(height: MarqueeSpace.m),
            Text(label, style: MarqueeText.of(context).label),
          ],
        ],
      ),
    );
  }
}

/// "Resuming from 14:32 · Start over", above the seek bar at the start
/// edge. It shows even when the controls are hidden.
class _Resumed extends StatelessWidget {
  const _Resumed({required this.from, required this.onStartOver});

  final Duration from;
  final VoidCallback onStartOver;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final width = MediaQuery.sizeOf(context).width;
    return SafeArea(
      child: Align(
        alignment: AlignmentDirectional.bottomStart,
        child: Padding(
          padding: EdgeInsetsDirectional.only(
            start: width >= 600 ? MarqueeSpace.xxxl : MarqueeSpace.l,
            bottom: 72,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: MarqueeColors.booth,
              border: Border.all(color: MarqueeColors.velvet),
              borderRadius: const BorderRadius.all(Radius.circular(999)),
            ),
            child: Padding(
              padding: const EdgeInsetsDirectional.only(start: MarqueeSpace.l),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.playerResumingFrom(formatClock(from)),
                    style: MarqueeText.of(context).label,
                  ),
                  const SizedBox(width: MarqueeSpace.xs),
                  TextButton(
                    onPressed: onStartOver,
                    style: withFocusRing(
                      TextButton.styleFrom(
                        foregroundColor: MarqueeColors.bulb,
                        minimumSize: const Size(44, 44),
                      ),
                    ),
                    child: Text(l10n.playerStartOver),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A short note above the centre buttons, e.g. "Fill" after the fit chip.
class _Toast extends StatelessWidget {
  const _Toast({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Align(
    alignment: const Alignment(0, -0.45),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: MarqueeColors.booth,
        border: Border.all(color: MarqueeColors.velvet),
        borderRadius: const BorderRadius.all(Radius.circular(999)),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(
          horizontal: MarqueeSpace.l,
          vertical: MarqueeSpace.s,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: MarqueeColors.cream),
            const SizedBox(width: MarqueeSpace.s),
            Text(label, style: MarqueeText.of(context).label),
          ],
        ),
      ),
    ),
  );
}

/// API errors go through [ErrorView] (it asks the status page once); stream
/// failures say so in the player's own words.
class _Failure extends StatelessWidget {
  const _Failure({
    required this.error,
    required this.onRetry,
    required this.onBack,
  });

  final Object? error;
  final VoidCallback onRetry;

  /// A title with no streams: trying again won't help (PLAYER.md §6).
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final error = this.error;
    final unavailable = error == PlayerFailure.unavailable;
    final Widget body = error is ApiException
        ? ErrorView(error: error, onRetry: onRetry)
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                unavailable ? l10n.playerUnavailable : l10n.playerFailed,
                textAlign: TextAlign.center,
                style: MarqueeText.of(context).body
                    .copyWith(color: MarqueeColors.creamSoft),
              ),
              const SizedBox(height: MarqueeSpace.l),
              unavailable
                  ? OutlinedButton(
                      onPressed: onBack,
                      child: Text(
                        MaterialLocalizations.of(context).backButtonTooltip,
                      ),
                    )
                  : OutlinedButton(onPressed: onRetry, child: Text(l10n.retry)),
            ],
          );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(MarqueeSpace.xxl),
          child: body,
        ),
      ),
    );
  }
}

/// Matches [logical] on any layout, and falls back to [physical] when a
/// non-Latin keyboard layout (such as Arabic on Windows) maps the key to a
/// non-ASCII Unicode character.
class _KeyActivator extends ShortcutActivator {
  const _KeyActivator(this.logical, this.physical);

  final LogicalKeyboardKey logical;
  final PhysicalKeyboardKey physical;

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (state.isControlPressed ||
        state.isAltPressed ||
        state.isMetaPressed ||
        state.isShiftPressed) {
      return false;
    }
    if (event.logicalKey == logical) return true;
    final id = event.logicalKey.keyId;
    final isNonLatinChar = id > 0x7F && id <= 0x10FFFF;
    return isNonLatinChar && event.physicalKey == physical;
  }

  @override
  String debugDescribeKeys() => logical.keyLabel;
}
