import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// Automatic app update.
///
/// Android will not let a normal app overwrite itself without the system
/// package installer, so "automatic" here means: notice the new version on the
/// website, download the APK in the background, verify it is a real archive,
/// then open the installer. The user confirms once and the app is replaced and
/// restarted — no store, no browser, no searching for the file.
class AppUpdater {
  AppUpdater._();

  static const _channel = MethodChannel('camanime/updater');

  static String _base() => apiHost.replaceFirst(RegExp(r'/+$'), '');

  /// Compares dotted versions. Returns true when [latest] is genuinely newer.
  static bool isNewer(String latest, String current) {
    List<int> parts(String v) => v
        .split(RegExp(r'[.+-]'))
        .map((e) => int.tryParse(e.trim()) ?? 0)
        .toList();
    final a = parts(latest);
    final b = parts(current);
    for (var i = 0; i < 3; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  /// Asks the website what the current release is.
  ///
  /// Returns null when the check cannot be made (offline, odd response), so an
  /// update check never blocks or breaks normal app use.
  static Future<UpdateInfo?> check({required String current}) async {
    try {
      final res = await http
          .get(Uri.parse('${_base()}/api/version'))
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return null;
      final data = json.decode(res.body);
      if (data is! Map) return null;
      final latest = (data['app_version'] ?? '').toString().trim();
      if (latest.isEmpty || !isNewer(latest, current)) return null;
      final rawUrl = (data['apk_url'] ?? '/get/android').toString();
      final url = rawUrl.startsWith('http')
          ? rawUrl
          : '${_base()}${rawUrl.startsWith('/') ? '' : '/'}$rawUrl';
      return UpdateInfo(
        version: latest,
        apkUrl: url,
        notes: (data['notes'] ?? '').toString(),
        sha256: (data['sha256'] ?? '').toString(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Downloads the new APK into app storage, reporting 0..1 progress.
  ///
  /// The downloaded file is only returned when its SHA-256 matches
  /// [info.sha256]. A mismatch (corrupt or tampered download) is treated as a
  /// failed download: the partial file is deleted and null is returned, so the
  /// installer never receives a bad or unauthorized APK.
  static Future<File?> download(
    UpdateInfo info, {
    void Function(double progress)? onProgress,
  }) async {
    try {
      final dir = await getTemporaryDirectory();
      final target = File('${dir.path}/CamAnime-${info.version}.apk');
      if (await target.exists()) await target.delete();
      final client = http.Client();
      try {
        final request = http.Request('GET', Uri.parse(info.apkUrl));
        final response = await client.send(request);
        if (response.statusCode != 200) return null;
        final total = response.contentLength ?? 0;
        var written = 0;
        final sink = target.openWrite();
        await for (final chunk in response.stream) {
          sink.add(chunk);
          written += chunk.length;
          if (total > 0 && onProgress != null) {
            onProgress((written / total).clamp(0.0, 1.0));
          }
        }
        await sink.flush();
        await sink.close();
      } finally {
        client.close();
      }
      // A network error page is a few hundred bytes, an APK is tens of MB.
      if (!await target.exists() || await target.length() < 5 * 1024 * 1024) {
        try {
          await target.delete();
        } catch (_) {}
        return null;
      }
      // Integrity check before the installer ever sees the file.
      if (info.sha256.isNotEmpty) {
        try {
          final digest = await compute(_sha256File, target.path);
          if (digest.isEmpty || digest.toUpperCase() != info.sha256.toUpperCase()) {
            debugPrint(
                'AppUpdater: APK sha256 mismatch (expected ${info.sha256}, got $digest). Deleting.');
            try {
              await target.delete();
            } catch (_) {}
            return null;
          }
        } catch (_) {
          // Hashing can only fail on a broken path; treat it as unsafe.
          try {
            await target.delete();
          } catch (_) {}
          return null;
        }
      }
      onProgress?.call(1);
      return target;
    } catch (_) {
      return null;
    }
  }

  /// SHA-256 of a file, returned as an uppercase hex string.
  ///
  /// Runs on the background isolate so hashing a ~53 MB APK does not freeze the
  /// UI.
  static Future<String> _sha256File(String path) async {
    final bytes = await File(path).readAsBytes();
    final hash = sha256.convert(bytes);
    return hash.toString().toUpperCase();
  }

  /// True when Android will show the installer without an extra permission trip.
  static Future<bool> canInstall() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('canInstall') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Sends the APK to the system installer. Returns false when Android needs
  /// "install unknown apps" enabled first (that screen is opened for the user).
  static Future<bool> install(File apk) async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('install', {'path': apk.path}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> openPermissionSettings() async {
    try {
      await _channel.invokeMethod<bool>('permissionSettings');
    } catch (_) {}
  }

  static Future<void> restart() async {
    try {
      await _channel.invokeMethod<bool>('restart');
    } catch (_) {}
  }

  /// Keep the download alive in the background so a large APK is not killed by
  /// the system while the app is not on screen.
  static Future<void> startForegroundForUpdate() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('startForegroundForUpdate');
    } catch (_) {}
  }

  /// Shared-prefs keys for the post-update "what's new" dialog.
  static const String _kWhatsNew = 'show_whats_new';
  static const String _kWhatsNewVersion = 'whats_new_version';
  static const String _kWhatsNewNotes = 'whats_new_notes';

  /// Reads and clears the post-update "what's new" flag. Returns the version and
  /// release notes the freshly installed app should show; returns (show: false)
  /// when nothing is pending.
  static Future<({bool show, String version, String notes})> whatsNew() async {
    final p = await SharedPreferences.getInstance();
    if (p.getBool(_kWhatsNew) != true) return (show: false, version: '', notes: '');
    final version = p.getString(_kWhatsNewVersion) ?? '';
    final notes = p.getString(_kWhatsNewNotes) ?? '';
    await p.setBool(_kWhatsNew, false);
    return (show: true, version: version, notes: notes);
  }

  /// Starts the update now — used when the user taps a live-update notification or
  /// the scheduled two-minute alarm fires. Downloads the APK in the foreground,
  /// verifies its SHA-256, installs and restarts; saves the release notes so the
  /// freshly installed app can show a what's-new dialog on first launch.
  static Future<void> startUpdateNow() async {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return;
    final navigator = Navigator.of(ctx, rootNavigator: true);
    final messenger = ScaffoldMessenger.of(ctx);
    bool snackOk() => messenger.mounted;

    // Start the foreground keep-alive so the download survives backgrounding.
    await startForegroundForUpdate();

    final installed = await installedVersion();
    final info = await check(current: installed);
    if (info == null) {
      messenger.showSnackBar(
          const SnackBar(content: Text('No update available now.')));
      return;
    }

    var ok = await canInstall();
    if (!ok) {
      await openPermissionSettings();
      messenger.showSnackBar(
          const SnackBar(content: Text('Install unknown apps permission needed.')));
      return;
    }

    bool disposed = false;
    void dismiss() {
      if (!disposed) {
        disposed = true;
        navigator.pop();
      }
    }

    final barrier = Dialog(
      backgroundColor: const Color(0xFF0A0D14),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.system_update,
                  size: 40, color: Color(0xFF087BFF)),
              const SizedBox(height: 14),
              const Text('Updating CamAnime',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Text('Downloading CamAnime ${info.version}…',
                  style: const TextStyle(color: Color(0xFFB7C3D9))),
              const SizedBox(height: 14),
              const LinearProgressIndicator()
            ]),
        ),
      ),
    );

    if (!navigator.mounted) return;
    navigator.push(dialogRoute(barrier));

    final file = await download(info, onProgress: (p) {
      UpdateState.progress.value = p;
    });
    UpdateState.progress.value = null;

    if (!navigator.mounted) return;
    dismiss();

    if (file == null) {
      if (snackOk()) {
        messenger.showSnackBar(
            const SnackBar(content: Text('Update download failed. Try again later.')));
      }
      return;
    }

    final installedNow = await install(file);
    if (!installedNow) {
      if (snackOk()) {
        messenger.showSnackBar(
            const SnackBar(content: Text('Install was not started. Try again.')));
      }
      return;
    }

    // Remember the release notes for the freshly installed app to show.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kWhatsNew, true);
    await prefs.setString(_kWhatsNewVersion, info.version);
    await prefs.setString(_kWhatsNewNotes, info.notes);

    // Restart into the newly installed app.
    await restart();
  }

  /// Real installed version, so a stale constant can never hide an update.
  static Future<String> installedVersion() async {
    if (!Platform.isAndroid) return '';
    try {
      return await _channel.invokeMethod<String>('versionName') ?? '';
    } catch (_) {
      return '';
    }
  }
}

class UpdateInfo {
  final String version;
  final String apkUrl;
  final String notes;
  final String sha256;
  const UpdateInfo({
    required this.version,
    required this.apkUrl,
    this.notes = '',
    this.sha256 = '',
  });
  @override
  String toString() => 'UpdateInfo($version, $apkUrl)';
}

/// Small listenable the UI can watch while an update installs.
class UpdateState {
  static final ValueNotifier<double?> progress = ValueNotifier<double?>(null);
}

/// Pushes a dialog onto the root navigator without needing a build context on the
/// material tree.
Route<void> dialogRoute(Widget child) {
  return PageRouteBuilder<void>(
    pageBuilder: (context, animation, secondaryAnimation) => child,
    barrierColor: Colors.black54,
    barrierDismissible: false,
  );
}
