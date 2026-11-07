import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Heads-up notifications for finished downloads.
///
/// The Android side owns the channel and the posting; this class only keeps the
/// user's preference and talks to the `camanime/notifications` channel, so the
/// app still builds and runs on Windows where there is no notification host.
class AppNotifications {
  static const MethodChannel _channel = MethodChannel('camanime/notifications');

  static const String prefKey = 'download_notifications';

  static bool _enabled = true;
  static bool _initialised = false;

  /// Creates the heads-up channel and asks for POST_NOTIFICATIONS on Android
  /// 13+. Safe to call more than once.
  static Future<void> init() async {
    if (!Platform.isAndroid || _initialised) return;
    _initialised = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(prefKey) ?? true;
      await _channel.invokeMethod<void>('init');
    } catch (_) {
      // Host unavailable (desktop, tests): notifications simply stay off.
    }
  }

  static bool get enabled => _enabled;

  static Future<void> setEnabled(bool value) async {
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKey, value);
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>(value ? 'enable' : 'disable');
    } catch (_) {}
  }

  /// Called by the download manager the moment a file is complete and renamed.
  /// Never throws: a missing notification must not affect the download itself.
  static Future<void> downloadComplete({
    required String animeTitle,
    required int episode,
    required String taskId,
  }) async {
    if (!Platform.isAndroid || !_enabled) return;
    try {
      await _channel.invokeMethod<void>('downloadComplete', {
        'title': animeTitle,
        'episode': episode,
        'id': taskId,
      });
    } catch (_) {}
  }
}
