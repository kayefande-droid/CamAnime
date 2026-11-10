import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'models.dart' show apiHost;
import 'version_gate.dart' show kAppBuildNumber;

/// Server-owned settings that can change without shipping a new APK.
///
/// The app always starts from [defaults] and only replaces a value the server
/// explicitly sent, so an unreachable or partial config API never breaks a
/// screen and never enables something by accident.
class RemoteConfig {
  RemoteConfig._();

  static const Map<String, dynamic> defaults = {
    'maintenance': {'enabled': false, 'message': ''},
    'banner': {'text': '', 'url': '', 'tone': 'info'},
    'featured_anime_id': '',
    'min_supported_build': 19,
    'recommended_build': 22,
    'update_notice': '',
    'announcement': '',
    'features': {
      'streaming': true,
      'downloads': true,
      'offline_library': true,
      'comments': true,
      'trailer': true,
    },
  };

  static final ValueNotifier<Map<String, dynamic>> values =
      ValueNotifier<Map<String, dynamic>>(_copy(defaults));

  /// True while the server asks the app to show a maintenance screen. Only the
  /// server can turn this on; the default is always off.
  static bool get maintenance => _bool('maintenance', 'enabled');
  static String get maintenanceMessage => _string('maintenance', 'message');

  static String get bannerText => _string('banner', 'text');
  static String get bannerUrl => _string('banner', 'url');
  static String get bannerTone => _string('banner', 'tone');
  static String get updateNotice => (values.value['update_notice'] ?? '').toString();
  static String get announcement => (values.value['announcement'] ?? '').toString();
  static String get featuredAnimeId =>
      (values.value['featured_anime_id'] ?? '').toString();

  static bool feature(String name) {
    final features = values.value['features'];
    if (features is Map && features[name] is bool) return features[name] as bool;
    final fallback = defaults['features'];
    return fallback is Map && fallback[name] is bool ? fallback[name] as bool : true;
  }

  static int get recommendedBuild {
    final v = values.value['recommended_build'];
    return v is int ? v : kAppBuildNumber;
  }

  static String _base() => apiHost.replaceFirst(RegExp(r'/+$'), '');

  /// Pull the latest config. Failure keeps the previous values (never resets
  /// them to an older server answer).
  static Future<void> refresh() async {
    try {
      final res = await http
          .get(Uri.parse('${_base()}/api/v1/app/config'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return;
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) return;
      final config = decoded['config'];
      if (config is! Map) return;
      values.value = _merge(defaults, config.cast<String, dynamic>());
    } catch (_) {
      // Offline: safe defaults stay in force.
    }
  }

  static bool _bool(String group, String key) {
    final section = values.value[group];
    if (section is Map && section[key] is bool) return section[key] as bool;
    final fallback = defaults[group];
    return fallback is Map ? fallback[key] == true : false;
  }

  static String _string(String group, String key) {
    final section = values.value[group];
    if (section is Map && section[key] != null) return section[key].toString();
    final fallback = defaults[group];
    return fallback is Map ? (fallback[key] ?? '').toString() : '';
  }

  static Map<String, dynamic> _copy(Map<String, dynamic> source) =>
      jsonDecode(jsonEncode(source)) as Map<String, dynamic>;

  /// Recursive merge restricted to keys that already exist in [defaults].
  static Map<String, dynamic> _merge(
      Map<String, dynamic> base, Map<String, dynamic> stored) {
    final out = _copy(base);
    for (final entry in stored.entries) {
      if (!out.containsKey(entry.key)) continue;
      final current = out[entry.key];
      final incoming = entry.value;
      if (current is Map && incoming is Map) {
        out[entry.key] =
            _merge(current.cast<String, dynamic>(), incoming.cast<String, dynamic>());
      } else if (incoming != null && incoming.runtimeType == current.runtimeType) {
        out[entry.key] = incoming;
      }
    }
    return out;
  }
}

/// One published APK release, as served by `GET /api/v1/app/update`.
class UpdateManifest {
  final String version;
  final int build;
  final String apkUrl;
  final String sha256;
  final int size;
  final bool mandatory;
  final bool updateRequired;
  final bool updateAvailable;
  final String notes;
  final String compatibility;

  const UpdateManifest({
    required this.version,
    required this.build,
    required this.apkUrl,
    required this.sha256,
    required this.size,
    required this.mandatory,
    required this.updateRequired,
    required this.updateAvailable,
    required this.notes,
    required this.compatibility,
  });

  static UpdateManifest? fromJson(Map<String, dynamic> json) {
    int asInt(dynamic v) => v is int ? v : int.tryParse('${v ?? ''}') ?? 0;
    final version = (json['version_name'] ?? '').toString();
    if (version.isEmpty) return null;
    return UpdateManifest(
      version: version,
      build: asInt(json['version_code']),
      apkUrl: (json['apk_url'] ?? '').toString(),
      sha256: (json['sha256'] ?? '').toString(),
      size: asInt(json['size']),
      mandatory: json['mandatory'] == true,
      updateRequired: json['update_required'] == true,
      updateAvailable: json['update_available'] == true,
      notes: (json['notes'] ?? '').toString(),
      compatibility: (json['compatibility'] ?? '').toString(),
    );
  }

  /// Fetch the manifest for this build. Returns null when offline or when the
  /// server answered something unusable — an update check never blocks the app.
  static Future<UpdateManifest?> fetch({int? build}) async {
    try {
      final base = apiHost.replaceFirst(RegExp(r'/+$'), '');
      final uri = Uri.parse(
          '$base/api/v1/app/update?build=${build ?? kAppBuildNumber}');
      final res = await http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) return null;
      return fromJson(decoded.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }
}
