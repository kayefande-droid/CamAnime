import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// One place that initialises Firebase, before `runApp`.
///
/// The Android options come from `android/app/google-services.json` through the
/// Google Services Gradle plugin, so no values are hardcoded here. A missing or
/// broken config is caught and the app still starts: every Firebase feature
/// checks [ready] before touching an SDK.
class FirebaseBoot {
  FirebaseBoot._();

  static bool _ready = false;
  static bool get ready => _ready;

  /// Analytics is optional and failures are swallowed: a tracking problem must
  /// never block a launch or a video.
  static FirebaseAnalytics? get analytics => _ready ? FirebaseAnalytics.instance : null;

  /// Call once from `main()` before `runApp()`.
  static Future<void> init({Duration timeout = const Duration(seconds: 10)}) async {
    if (_ready) return;
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp().timeout(timeout);
      }
      _ready = Firebase.apps.isNotEmpty;
    } catch (err) {
      debugPrint('Firebase unavailable, continuing without it: $err');
      _ready = false;
      return;
    }

    // Analytics must never delay the first frame; enable it in the background.
    unawaited(() async {
      try {
        await FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(true);
      } catch (err) {
        debugPrint('Analytics not enabled: $err');
      }
    }());
  }

  /// Route tracking for a screen view. Safe to call at any time.
  static void screen(String name) {
    if (!_ready || name.isEmpty) return;
    unawaited(() async {
      try {
        await FirebaseAnalytics.instance.logScreenView(screenName: name);
      } catch (_) {
        // Analytics is best-effort.
      }
    }());
  }

  /// Business event logging (episode start, download finished, update seen …).
  static void event(String name, [Map<String, Object>? params]) {
    if (!_ready || name.isEmpty) return;
    unawaited(() async {
      try {
        await FirebaseAnalytics.instance.logEvent(name: name, parameters: params);
      } catch (_) {
        // Analytics is best-effort.
      }
    }());
  }
}
