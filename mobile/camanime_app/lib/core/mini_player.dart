import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import 'pip.dart';

/// The episode that keeps playing after the player screen is dismissed.
///
/// The mini bar does not create its own decoder: it holds the *same*
/// [VideoPlayerController] the full player was using, so pause, seek and the
/// displayed position are inherently one session. Tapping the bar detaches the
/// controller and re-opens the full player on top of it at the exact position.
class MiniPlayback {
  MiniPlayback({
    required this.controller,
    required this.title,
    this.subtitle = '',
    this.image = '',
    this.rebuild,
  });

  final VideoPlayerController controller;
  final String title;
  final String subtitle;
  final String image;

  /// Rebuilds the full player around this live session. The callback receives
  /// the live playback so the new page can adopt the very same controller.
  final Widget Function(MiniPlayback live)? rebuild;

  bool get isPlaying => controller.value.isPlaying;
  bool get ready => controller.value.isInitialized;
  Duration get position => controller.value.position;
  Duration get duration => controller.value.duration;
}

/// App-wide owner of the mini-player. One episode at a time; starting another
/// closes the previous one so two soundtracks can never play together.
class MiniPlayer {
  MiniPlayer._();

  static final ValueNotifier<MiniPlayback?> current =
      ValueNotifier<MiniPlayback?>(null);

  /// Bumped whenever the live session moves or toggles, so the bar redraws
  /// without the hub owning any widget state.
  static final ValueNotifier<int> tick = ValueNotifier<int>(0);

  static MiniPlayback? _live;
  static Timer? _ticker;

  /// Takes ownership of a controller that is already initialised (the full
  /// player handed it over). Playback continues without re-buffering, so
  /// minimizing does not restart the episode.
  static bool adopt({
    required VideoPlayerController controller,
    required String title,
    String subtitle = '',
    String image = '',
    Widget Function(MiniPlayback live)? rebuild,
  }) {
    if (!controller.value.isInitialized) return false;
    _release();
    final playback = MiniPlayback(
      controller: controller,
      title: title,
      subtitle: subtitle,
      image: image,
      rebuild: rebuild,
    );
    _live = playback;
    controller.addListener(_pump);
    current.value = playback;
    PiP.arm(true);
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      // Position changes do not notify on their own; nudge the bar along.
      _bump();
    });
    _bump();
    return true;
  }

  static void _pump() => _bump();

  static void _bump() {
    tick.value = tick.value + 1;
  }

  /// Hands the controller back to the full player without pausing or
  /// disposing it. Returns null when nothing is playing.
  static MiniPlayback? detach() {
    final live = _live;
    if (live == null) return null;
    _release();
    return live;
  }

  static Future<void> toggle() async {
    final live = _live;
    if (live == null) return;
    try {
      if (live.controller.value.isPlaying) {
        await live.controller.pause();
      } else {
        await live.controller.play();
      }
    } catch (_) {
      // Controller torn down mid-tap: nothing left to control.
    }
    _bump();
  }

  /// Seeks the live session by [delta], clamped to the episode boundaries so
  /// a tap can never seek before 0:00 or past the end.
  static Future<void> seekBy(Duration delta) async {
    final live = _live;
    if (live == null || !live.ready) return;
    final total = live.controller.value.duration;
    final target = live.controller.value.position + delta;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (total > Duration.zero && target > total ? total : target);
    try {
      await live.controller.seekTo(clamped);
    } catch (_) {}
    _bump();
  }

  static Future<void> close() async {
    final live = detach();
    if (live == null) return;
    try {
      await live.controller.pause();
    } catch (_) {}
    try {
      await live.controller.dispose();
    } catch (_) {}
  }

  /// Internal: stops timers/alarms and forgets the live session, leaving the
  /// controller itself alive for the caller.
  static void _release() {
    PiP.arm(false);
    _ticker?.cancel();
    _ticker = null;
    final live = _live;
    _live = null;
    current.value = null;
    if (live != null) {
      try {
        live.controller.removeListener(_pump);
      } catch (_) {}
    }
  }
}
