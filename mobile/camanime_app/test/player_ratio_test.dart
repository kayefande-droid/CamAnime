import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:camanime_app/core/player_ratio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const video16x9 = 16 / 9;
  const video4x3 = 4 / 3;
  const video21x9 = 21 / 9;
  const screenLandscape = 2400 / 1080;
  const screenPortrait = 1080 / 2400;

  group('frame math', () {
    test('auto always follows the video', () {
      for (final ratio in [video16x9, video4x3, video21x9]) {
        expect(
          PlayerRatio.auto.frameAspect(
            videoAspect: ratio,
            screenAspect: screenLandscape,
            fullscreen: true,
          ),
          ratio,
        );
      }
    });

    test('fit and fill take the whole screen in fullscreen', () {
      for (final mode in [PlayerRatio.fit, PlayerRatio.fill]) {
        expect(
          mode.frameAspect(
            videoAspect: video16x9,
            screenAspect: screenLandscape,
            fullscreen: true,
          ),
          screenLandscape,
        );
        // Portrait rotation must be handled too.
        expect(
          mode.frameAspect(
            videoAspect: video16x9,
            screenAspect: screenPortrait,
            fullscreen: true,
          ),
          screenPortrait,
        );
      }
      expect(PlayerRatio.fit.videoFit, BoxFit.contain);
      expect(PlayerRatio.fill.videoFit, BoxFit.cover);
    });

    test('inline playback never forces the screen ratio', () {
      for (final mode in PlayerRatio.values) {
        final aspect = mode.frameAspect(
          videoAspect: video4x3,
          screenAspect: screenPortrait,
          fullscreen: false,
        );
        expect(aspect, mode.isFixed ? mode.forcedAspect : video4x3);
      }
    });

    test('fixed modes pin their ratio regardless of the video', () {
      expect(
        PlayerRatio.widescreen.frameAspect(
          videoAspect: video4x3,
          screenAspect: screenLandscape,
          fullscreen: true,
        ),
        16 / 9,
      );
      expect(
        PlayerRatio.classic.frameAspect(
          videoAspect: video16x9,
          screenAspect: screenLandscape,
          fullscreen: true,
        ),
        4 / 3,
      );
      expect(
        PlayerRatio.cinema.frameAspect(
          videoAspect: video16x9,
          screenAspect: screenLandscape,
          fullscreen: true,
        ),
        21 / 9,
      );
    });

    test('stretch fills the screen without cropping', () {
      expect(PlayerRatio.stretch.videoFit, BoxFit.fill);
      expect(
        PlayerRatio.stretch.frameAspect(
          videoAspect: video21x9,
          screenAspect: screenPortrait,
          fullscreen: true,
        ),
        screenPortrait,
      );
    });
  });

  group('persistence', () {
    test('defaults to auto when nothing is stored', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await PlayerRatioPrefs.load(), PlayerRatio.auto);
    });

    test('round-trips every mode', () async {
      for (final mode in PlayerRatio.values) {
        SharedPreferences.setMockInitialValues({});
        await PlayerRatioPrefs.save(mode);
        expect(await PlayerRatioPrefs.load(), mode);
      }
    });

    test('unknown or corrupt values fall back to auto', () {
      expect(PlayerRatio.fromKey(null), PlayerRatio.auto);
      expect(PlayerRatio.fromKey('pancake'), PlayerRatio.auto);
      expect(PlayerRatio.fromKey('classic'), PlayerRatio.classic);
    });
  });
}
