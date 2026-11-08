import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import 'pip.dart';

/// The episode that keeps playing after the player screen is dismissed.
///
/// Everything the mini bar needs lives here, including a builder that can
/// recreate the full player page when the bar is tapped, so audio never stops
/// just because the user went back to browsing.
class MiniPlayback {
  MiniPlayback({
    required this.controller,
    required this.title,
    required this.subtitle,
    this.image = '',
    this.rebuild,
  });

  final VideoPlayerController controller;
  final String title;
  final String subtitle;
  final String image;
  final Widget Function()? rebuild;

  bool get isPlaying => controller.value.isPlaying;
  Duration get position => controller.value.position;
}

/// App-wide owner of the miniplayer. One episode at a time; starting another
/// closes the previous one so two soundtracks can never play together.
class MiniPlayer {
  MiniPlayer._();

  static final ValueNotifier<MiniPlayback?> current =
      ValueNotifier<MiniPlayback?>(null);

  /// Bumped whenever the playing episode moves or toggles, so the bar redraws
  /// progress without the hub owning any widget state.
  static final ValueNotifier<int> tick = ValueNotifier<int>(0);

  static MiniPlayback? _live;
  static Timer? _ticker;

  /// Takes over playback from the full player: a fresh controller starts at the
  /// position the user left, paused or playing, and keeps a timer running so the
  /// bar can redraw its progress.
  static Future<bool> start({
    required String url,
    required String title,
    String subtitle = '',
    String image = '',
    Duration position = Duration.zero,
    bool play = true,
    Widget Function()? rebuild,
  }) async {
    await close();
    if (url.trim().isEmpty) return false;
    final controller = url.startsWith('/') || url.startsWith('file:')
        ? VideoPlayerController.file(File(url.replaceFirst('file://', '')))
        : VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await controller.initialize().timeout(const Duration(seconds: 15));
    } catch (_) {
      try {
        await controller.dispose();
      } catch (_) {}
      return false;
    }
    if (position > Duration.zero) {
      try {
        await controller.seekTo(position);
      } catch (_) {}
    }
    if (play) {
      try {
        await controller.play();
      } catch (_) {}
    }
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
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      // Position changes do not notify on their own; nudge the bar along.
      if (_live != null) _bump();
    });
    return true;
  }

  static void _pump() => _bump();

  static void _bump() {
    tick.value = tick.value + 1;
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
    } catch (_) {}
    _bump();
  }

  static Future<void> close() async {
    PiP.arm(false);
    _ticker?.cancel();
    _ticker = null;
    final live = _live;
    _live = null;
    current.value = null;
    if (live == null) return;
    live.controller.removeListener(_pump);
    try {
      await live.controller.pause();
    } catch (_) {}
    try {
      await live.controller.dispose();
    } catch (_) {}
  }

  static Future<void> handOver() async {
    // The full player is about to take control again.
    await close();
  }
}
