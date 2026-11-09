import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

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
  static const String _seenAnnouncementsKey = 'seen_announcement_ids';

  /// Shows the newest admin announcement once, as a heads-up notification.
  ///
  /// This is the no-Firebase delivery path: the app reads the same
  /// `/api/announcements` feed the website banner uses, so an announcement
  /// published from /admin still reaches installs that have no push token.
  /// Announcements are marked seen as soon as they are fetched, so a user gets
  /// one alert per message, never a backlog on every launch.
  static Future<void> announcements(List<dynamic> items) async {
    if (!Platform.isAndroid || !_enabled || items.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final seen = (prefs.getStringList(_seenAnnouncementsKey) ?? <String>[])
          .toSet();
      Map<String, dynamic>? newest;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      for (final item in items) {
        if (item is! Map) continue;
        final id = (item['id'] ?? '').toString();
        if (id.isEmpty) continue;
        final ts = (item['t'] as num?)?.toInt() ?? 0;
        if (!seen.contains(id) &&
            newest == null &&
            (ts == 0 || now - ts < 60 * 60 * 24 * 30)) {
          newest = item.cast<String, dynamic>();
        }
        seen.add(id);
      }
      if (newest == null) return;
      final action = (newest['action'] ?? '').toString();
      String? version;
      if (action == 'update') {
        try {
          final uri = Uri.parse('https://camanime.onrender.com/api/version');
          final r = await http.get(uri).timeout(const Duration(seconds: 10));
          if (r.statusCode == 200) {
            final v = jsonDecode(r.body) as Map<String, dynamic>;
            version = v['app_version']?.toString();
          }
        } catch (_) {}
      }
      await _channel.invokeMethod<void>('announcement', {
        'id': newest['id'].toString(),
        'title': (newest['title'] ?? 'CamAnime').toString(),
        'body': (newest['body'] ?? '').toString(),
        if (version != null && version.isNotEmpty) 'version': version,
        if (action.isNotEmpty) 'action': action,
      });
      // Mark this announcement seen so the bell and future launches stay quiet.
      await prefs.setStringList(
          _seenAnnouncementsKey, seen.take(80).toList(growable: false));
    } catch (_) {
      // Announcements are optional chrome: never break the catalogue load.
    }
  }

  static Future<void> downloadComplete({
    required String animeTitle,
    required int episode,
    required String taskId,
    String? imageUrl,
  }) async {
    if (!Platform.isAndroid || !_enabled) return;
    try {
      await _channel.invokeMethod<void>('downloadComplete', {
        'title': animeTitle,
        'episode': episode,
        'id': taskId,
        if (imageUrl != null && imageUrl.isNotEmpty) 'image': imageUrl,
      });
    } catch (_) {}
  }

  /// Heads-up for a in-app update being downloaded.
  ///
  /// Posted once per update check, before the download dialog, so the user sees
  /// the update even when the dialog is behind another app. The key is the
  /// version string, so repeated checks for the same version reuse the same
  /// notification.
  static Future<void> updateInProgress(String version) async {
    if (!Platform.isAndroid || !_enabled) return;
    try {
      await _channel.invokeMethod<void>('updateInProgress', {
        'version': version,
      });
    } catch (_) {}
  }

  /// Dismisses the "Live update going on" heads-up notification if one is
  /// showing. Safe to call even when no update is in flight; the native side is
  /// a no-op when the notification channel or notification is absent.
  static Future<void> dismissUpdateInProgress() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('dismissUpdateInProgress');
    } catch (_) {}
  }
}
