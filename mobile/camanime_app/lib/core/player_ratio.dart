import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How the player frames the video inside the space it is given.
///
/// [auto] and [fit] both keep the whole frame visible; they differ in whether
/// the black bars wrap the video (auto) or the screen (fit). Everything that is
/// not [auto] survives fullscreen changes and app restarts, because a viewer
/// who wants 4:3 wants it on the next episode too.
enum PlayerRatio {
  auto(
    label: 'Auto',
    description: 'Original video ratio',
    icon: Icons.smart_display_rounded,
    videoFit: BoxFit.contain,
  ),
  fit(
    label: 'Fit Screen',
    description: 'Whole video, bars around it',
    icon: Icons.fit_screen_rounded,
    videoFit: BoxFit.contain,
  ),
  fill(
    label: 'Fill Screen',
    description: 'Crop the edges to fill',
    icon: Icons.crop_free_rounded,
    videoFit: BoxFit.cover,
  ),
  widescreen(
    label: '16:9',
    description: 'Standard widescreen',
    icon: Icons.crop_16_9_rounded,
    videoFit: BoxFit.contain,
    forcedAspect: 16 / 9,
  ),
  classic(
    label: '4:3',
    description: 'Classic television',
    icon: Icons.crop_5_4_rounded,
    videoFit: BoxFit.contain,
    forcedAspect: 4 / 3,
  ),
  cinema(
    label: '21:9',
    description: 'Ultra-wide cinema',
    icon: Icons.panorama_wide_angle_rounded,
    videoFit: BoxFit.contain,
    forcedAspect: 21 / 9,
  ),
  stretch(
    label: 'Stretch',
    description: 'Fill, ignoring proportions',
    icon: Icons.swap_horiz_rounded,
    videoFit: BoxFit.fill,
  );

  const PlayerRatio({
    required this.label,
    required this.description,
    required this.icon,
    required this.videoFit,
    this.forcedAspect,
  });

  final String label;
  final String description;
  final IconData icon;

  /// How the texture is painted inside the frame.
  final BoxFit videoFit;

  /// Fixed frame ratio; null means "derive it from the video / screen".
  final double? forcedAspect;

  /// True when the mode pins a frame ratio of its own.
  bool get isFixed => forcedAspect != null;

  /// Ratio of the black frame the video sits in.
  ///
  /// * auto / fit on a plain screen: the video's own ratio, so the page around
  ///   it is laid out exactly like before.
  /// * fit / fill / stretch in fullscreen: the whole screen, which is what
  ///   makes "fill" actually fill and "fit" letterbox against the screen edge.
  /// * fixed modes: the requested ratio wherever there is room for it.
  double frameAspect({
    required double videoAspect,
    required double screenAspect,
    required bool fullscreen,
  }) {
    final forced = forcedAspect;
    if (forced != null) return forced;
    if (!fullscreen) return videoAspect;
    switch (this) {
      case PlayerRatio.fit:
      case PlayerRatio.fill:
      case PlayerRatio.stretch:
        return screenAspect <= 0 ? videoAspect : screenAspect;
      case PlayerRatio.auto:
      case PlayerRatio.widescreen:
      case PlayerRatio.classic:
      case PlayerRatio.cinema:
        return videoAspect;
    }
  }

  static PlayerRatio fromKey(String? key) {
    for (final mode in PlayerRatio.values) {
      if (mode.name == key) return mode;
    }
    return PlayerRatio.auto;
  }
}

/// Persists the chosen mode. Failure to read or write must never block
/// playback, so every error falls back to [PlayerRatio.auto].
class PlayerRatioPrefs {
  static const String key = 'player_screen_ratio';

  static Future<PlayerRatio> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return PlayerRatio.fromKey(prefs.getString(key));
    } catch (_) {
      return PlayerRatio.auto;
    }
  }

  static Future<void> save(PlayerRatio mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, mode.name);
    } catch (_) {
      // Preference writes are best-effort; the in-memory choice still applies.
    }
  }
}
