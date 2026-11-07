import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Schedules the Android advert notifications (two per hour) and routes taps
/// back into the app. No-op on desktop, where there is no notification host.
///
/// The actual scheduling and catalogue fetch happen in the Android
/// [AdvertWorker]; this class only persists the preference and talks to the
/// native channel, so the app still builds and runs on Windows.
class AdNotifications {
  static const MethodChannel _adverts = MethodChannel('camanime/adverts');
  static const MethodChannel _navigation = MethodChannel('camanime/navigation');

  static const String prefKey = 'advert_notifications';

  /// Two notifications per hour (one every 30 minutes).
  static const int perHour = 2;

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(prefKey) ?? true;
  }

  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKey, value);
    if (!Platform.isAndroid) return;
    await _invoke(value ? 'start' : 'stop');
  }

  /// Starts (or stops) the schedule and listens for notification taps. The
  /// callback receives the real anime id + title from the notification.
  static Future<void> init({
    required void Function(String animeId, String title) onOpen,
  }) async {
    if (!Platform.isAndroid) return;
    _navigation.setMethodCallHandler((call) async {
      if (call.method != 'openAdvert') return;
      final data = (call.arguments as Map?) ?? const {};
      onOpen('${data['anime_id'] ?? ''}', '${data['title'] ?? ''}');
    });
    if (!await isEnabled()) {
      await _invoke('stop');
      return;
    }
    await _invoke('start');
    try {
      // Cold start: the notification that launched the app.
      final initial =
          await _navigation.invokeMapMethod<String, String>('getInitialAdvert');
      if (initial != null) {
        onOpen(initial['anime_id'] ?? '', initial['title'] ?? '');
      }
    } catch (_) {
      // No pending advert or channel unavailable.
    }
  }

  static Future<void> _invoke(String method) async {
    try {
      await _adverts.invokeMethod<void>(method);
    } catch (_) {
      // Host unavailable (tests/desktop): notifications simply stay off.
    }
  }
}
