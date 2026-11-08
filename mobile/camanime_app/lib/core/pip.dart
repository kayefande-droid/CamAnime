import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android picture-in-picture bridge.
///
/// Once armed, leaving CamAnime (home button, recents, another app) shrinks the
/// playing episode into the system's small floating window above other apps.
/// The window carries Android's own close button; closing it reports back here
/// so the miniplayer does not keep a decoder running.
class PiP {
  PiP._();

  static const MethodChannel _channel = MethodChannel('camanime/pip');

  static bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  /// Whether this device can float a window above other apps at all.
  static Future<bool> supported() async {
    if (!_isAndroid) return false;
    try {
      final value = await _channel.invokeMethod<bool>('supported');
      return value ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Arms (or disarms) the automatic shrink when leaving the app.
  static Future<void> arm(bool armed) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('arm', {'armed': armed});
    } catch (_) {}
  }

  /// Shrinks right now, e.g. from the miniplayer's pop-out button.
  static Future<bool> enter() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('enter') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// [onChanged] fires when the floating window opens or is dismissed.
  static void listen(void Function(bool inPip) onChanged) {
    if (!_isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pipEntered') onChanged(true);
      if (call.method == 'pipClosed') onChanged(false);
      return null;
    });
  }
}
