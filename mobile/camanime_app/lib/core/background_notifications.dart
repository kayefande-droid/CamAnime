import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'models.dart' show apiHost;
import 'version_gate.dart' show kAppVersion;

/// Background delivery for installs that never got an FCM token.
///
/// FCM posts an OS notification from the server when it is configured. This is
/// the second path, and it does not depend on the app being open or on a
/// server secret: Android wakes a WorkManager job every few hours, the job
/// reads the same announcement feed and version manifest the app uses, and
/// posts a notification for anything it has not already reported.
///
/// The job is deliberately conservative — it never notifies for the build the
/// user is already running, it remembers what it reported, and it silently
/// does nothing when notifications are switched off in Settings.
class BackgroundNotifications {
  BackgroundNotifications._();

  /// Unique + task names for the periodic job.
  static const String taskName = 'camanime.background.refresh';
  static const String _channelId = 'camanime_updates';
  static const String _channelName = 'Announcements and app updates';
  static const String _seenAnnouncementsKey = 'bg_seen_announcement_ids';
  static const String _seenVersionKey = 'bg_seen_version';
  static const String _notificationsPref = 'download_notifications';

  /// Six hours is frequent enough that a new episode/release is never a day
  /// old, and infrequent enough that the OS does not throttle the job.
  static const Duration interval = Duration(hours: 6);

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _ready = false;

  /// Creates the notification channel and schedules the periodic job.
  /// Safe to call on every launch; WorkManager keeps one periodic job.
  static Future<void> init() async {
    if (!Platform.isAndroid || _ready) return;
    _ready = true;
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      );
      await _plugin.initialize(settings: settings);
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description:
            'New episodes, new builds and admin announcements, delivered '
            'while the app is closed.',
        importance: Importance.high,
      ));
      await android?.requestNotificationsPermission();

      await Workmanager().initialize(camAnimeBackgroundDispatcher);
      await Workmanager().registerPeriodicTask(
        taskName,
        taskName,
        frequency: interval,
        constraints: Constraints(networkType: NetworkType.connected),
      );
    } catch (err) {
      // A device that refuses background work still gets foreground alerts.
      debugPrint('Background notifications unavailable: $err');
    }
  }

  /// Runs in the WorkManager isolate: fetch, compare, notify.
  static Future<void> checkAndNotify() async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(_notificationsPref) ?? true)) return;

    final client = http.Client();
    try {
      await _checkAnnouncements(client, prefs);
      await _checkRelease(client, prefs);
    } catch (_) {
      // Offline, host down or a malformed response: try again next wake-up.
    } finally {
      client.close();
    }
  }

  static Future<void> _checkAnnouncements(
      http.Client client, SharedPreferences prefs) async {
    final res = await client
        .get(Uri.parse('${_base()}/api/announcements'))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) return;
    final decoded = json.decode(res.body);
    final items = (decoded is Map ? decoded['announcements'] : null) as List? ??
        const [];
    final seen = (prefs.getStringList(_seenAnnouncementsKey) ?? const <String>[])
        .toSet();
    var changed = false;
    for (final item in items) {
      if (item is! Map) continue;
      final id = '${item['id'] ?? ''}';
      if (id.isEmpty || seen.contains(id)) continue;
      final title = (item['title'] ?? 'CamAnime').toString().trim();
      final body = (item['body'] ?? '').toString().trim();
      if (title.isEmpty && body.isEmpty) continue;
      await _show(id.hashCode & 0x7fffffff, title.isEmpty ? 'CamAnime' : title,
          body);
      seen.add(id);
      changed = true;
    }
    if (changed) {
      await prefs.setStringList(
          _seenAnnouncementsKey, seen.take(120).toList(growable: false));
    }
  }

  static Future<void> _checkRelease(
      http.Client client, SharedPreferences prefs) async {
    final res = await client
        .get(Uri.parse('${_base()}/api/version'))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) return;
    final decoded = json.decode(res.body);
    if (decoded is! Map) return;
    final latest = (decoded['app_version'] ?? '').toString().trim();
    if (latest.isEmpty || latest == kAppVersion) return;
    if (prefs.getString(_seenVersionKey) == latest) return;
    await prefs.setString(_seenVersionKey, latest);
    final notes = (decoded['whats_new'] ?? decoded['release_notes'] ?? '')
        .toString()
        .trim();
    await _show(
      0x0CA11,
      'CamAnime $latest is available',
      notes.isEmpty
          ? 'A newer build is published. Open the app to update.'
          : notes,
    );
  }

  static Future<void> _show(int id, String title, String body) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription:
            'New episodes, new builds and admin announcements, delivered '
            'while the app is closed.',
        importance: Importance.high,
        priority: Priority.high,
        styleInformation: BigTextStyleInformation(''),
      ),
    );
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
    );
  }

  static String _base() => apiHost.replaceFirst(RegExp(r'/+$'), '');
}

/// Entry point WorkManager calls in its own isolate.
@pragma('vm:entry-point')
void camAnimeBackgroundDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    await BackgroundNotifications.checkAndNotify();
    // true = work finished; a false result would be retried with backoff.
    return true;
  });
}
