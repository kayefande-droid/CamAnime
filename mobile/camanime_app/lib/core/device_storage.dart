import 'dart:io';

import 'package:flutter/services.dart';

/// Copies finished offline episodes into the phone's public storage, where
/// any gallery, file manager or media app can open them — and where they
/// survive an app uninstall.
///
/// Android 10+ writes through MediaStore (`Download/CamAnime/<anime>/<season>`)
/// with no storage permission at all; older releases use the legacy public
/// Downloads directory and the WRITE_EXTERNAL_STORAGE permission. Other
/// platforms simply report "unsupported" instead of failing the download.
class DeviceStorage {
  static const MethodChannel _channel = MethodChannel('camanime/storage');

  static bool get supported => Platform.isAndroid;

  /// Saves [sourcePath] into `Download/CamAnime/<folder>/[<subfolder>/]<name>`.
  ///
  /// Returns a human-readable location when the copy succeeded, or null when
  /// the platform cannot do it — never throws, because the in-app offline copy
  /// must stay usable either way.
  static Future<String?> save({
    required String sourcePath,
    required String folder,
    String subfolder = '',
    required String fileName,
  }) async {
    if (!supported) return null;
    try {
      final result = await _channel.invokeMethod<String>('save', {
        'path': sourcePath,
        'folder': folder,
        'subfolder': subfolder,
        'name': fileName,
      });
      final value = (result ?? '').trim();
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  /// Opens the system Downloads UI. Best effort; no effect when unavailable.
  static Future<void> openDownloads() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('openDownloads');
    } catch (_) {}
  }

  /// Removes a previously exported copy (the in-app file is untouched).
  static Future<void> deleteExported(String location) async {
    if (!supported || location.isEmpty) return;
    try {
      await _channel.invokeMethod<void>('delete', {'location': location});
    } catch (_) {}
  }
}
