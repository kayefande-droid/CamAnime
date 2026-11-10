import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_boot.dart';
import 'models.dart' show apiHost;
import 'version_gate.dart' show kAppVersion, kAppBuildNumber, VersionGate;

/// Topics a device can opt into. Keep in step with `TOPICS` in the worker's
/// `cloudflare/src/appapi.js`.
const List<String> kPushTopics = [
  'all',
  'new_anime',
  'new_episodes',
  'dubbed',
  'subbed',
  'app_updates',
  'maintenance',
  'announcements',
];

const Map<String, String> kPushTopicLabels = {
  'new_anime': 'New anime',
  'new_episodes': 'New episodes',
  'dubbed': 'Dubbed episodes',
  'subbed': 'Subbed episodes',
  'app_updates': 'App updates',
  'maintenance': 'Maintenance',
  'announcements': 'Announcements',
};

const String _topicsKey = 'push_topics';

/// Runs in its own isolate when a data message arrives with the app closed.
/// Nothing here may touch UI; the OS posts the notification payload itself.
@pragma('vm:entry-point')
Future<void> camAnimeBackgroundHandler(RemoteMessage message) async {
  try {
    if (Firebase.apps.isEmpty) await Firebase.initializeApp();
  } catch (_) {
    // No Firebase config in this build: the OS notification still shows.
  }
}

/// Push registration and notification routing.
///
/// Everything is defensive: a build without a `google-services.json` (or a
/// device that denies notifications) leaves the app fully usable, and the
/// server simply sees no push token for that install.
class PushService {
  PushService._();

  static bool _initialised = false;
  static bool _firebaseReady = false;

  /// Last foreground message, for an in-app banner.
  static final ValueNotifier<Map<String, dynamic>?> foreground =
      ValueNotifier(null);

  /// Deep link from a tapped notification, consumed by the app shell.
  static final ValueNotifier<String?> pendingLink = ValueNotifier(null);

  static bool get available => _firebaseReady;
  static bool get notificationsAllowed => _firebaseReady && _allowed;
  static bool _allowed = false;

  static List<String> get topics {
    final stored = _cachedTopics;
    if (stored != null) return stored;
    return const ['all', 'new_episodes', 'app_updates'];
  }

  static List<String>? _cachedTopics;
  static String? _lastToken;

  /// Registers the background isolate handler. Called synchronously from
  /// `main()` before `runApp`, because a message can be delivered while the
  /// app is still starting and the handler must already be installed.
  static void registerBackgroundHandler() {
    try {
      FirebaseMessaging.onBackgroundMessage(camAnimeBackgroundHandler);
    } catch (err) {
      debugPrint('Background push handler not registered: $err');
    }
  }

  /// Initialise Firebase, ask for permission and register this install.
  /// Safe to call more than once.
  static Future<void> init() async {
    if (_initialised) return;
    _initialised = true;

    // main() already booted Firebase before runApp; this is the belt-and-braces
    // path for a resume or a second call.
    if (!FirebaseBoot.ready) await FirebaseBoot.init();
    if (!FirebaseBoot.ready) {
      debugPrint('Push disabled: Firebase is not configured in this build.');
      // Still register the install so announcements/history stay useful.
      await _register('');
      return;
    }
    _firebaseReady = true;

    try {
      registerBackgroundHandler();
      final messaging = FirebaseMessaging.instance;
      final settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      _allowed = settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;

      await _loadTopics();

      if (!_allowed) {
        await _register('');
        return;
      }

      final token = await messaging.getToken();
      _lastToken = token;
      await _register(token ?? '');

      messaging.onTokenRefresh.listen((fresh) {
        _lastToken = fresh;
        unawaited(_register(fresh));
      });

      FirebaseMessaging.onMessage.listen(_onForeground);
      FirebaseMessaging.onMessageOpenedApp.listen(_onOpened);
      final initial = await messaging.getInitialMessage();
      if (initial != null) _onOpened(initial);
    } catch (err) {
      debugPrint('Push registration failed: $err');
    }
  }

  /// Opt a topic in or out and re-register. `all` can never be removed.
  static Future<void> setTopic(String topic, bool enabled) async {
    if (!kPushTopics.contains(topic) || topic == 'all') return;
    final next = {...topics};
    if (enabled) {
      next.add(topic);
    } else {
      next.remove(topic);
    }
    _cachedTopics = next.toList()..sort();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_topicsKey, _cachedTopics!);
    await _register(_lastToken ?? '');
  }

  /// Turn notifications off for this install (keeps the account row).
  static Future<void> disable() async {
    _cachedTopics = const ['all'];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_topicsKey, _cachedTopics!);
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {}
    _lastToken = null;
    await _register('');
  }

  static Future<void> _loadTopics() async {
    if (_cachedTopics != null) return;
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_topicsKey);
    _cachedTopics = stored != null && stored.isNotEmpty
        ? stored
        : const ['all', 'new_episodes', 'app_updates'];
  }

  static String _base() => apiHost.replaceFirst(RegExp(r'/+$'), '');

  static Future<void> _register(String token) async {
    try {
      final installId = await VersionGate.installId();
      final body = jsonEncode({
        'install_id': installId,
        'token': token,
        'platform': Platform.isAndroid ? 'android' : 'other',
        'app_version': kAppVersion,
        'app_build': kAppBuildNumber,
        'android_version': Platform.operatingSystemVersion
            .replaceFirst('android ', '')
            .split(' ')
            .first,
        'language': Platform.localeName,
        'topics': topics,
      });
      final res = await http
          .post(
            Uri.parse('${_base()}/api/v1/devices/register'),
            headers: {'content-type': 'application/json'},
            body: body,
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode >= 300) {
        debugPrint('Device registration answered ${res.statusCode}');
      }
    } catch (err) {
      debugPrint('Device registration failed: $err');
    }
  }

  static void _onForeground(RemoteMessage message) {
    foreground.value = {
      'title': message.notification?.title ?? '',
      'body': message.notification?.body ?? '',
      ...message.data,
    };
  }

  static void _onOpened(RemoteMessage message) {
    final link = (message.data['deep_link'] ?? '').toString().trim();
    if (link.isEmpty) return;
    pendingLink.value = link;
  }
}
