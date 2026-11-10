import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';

/// Tracks update download and install state used by the UI.
class UpdateState {
  static final progress = ValueNotifier<double>(0.0);
}

/// Automatic app update.
///
/// Android will not let a normal app overwrite itself without the system
/// package installer, so "automatic" here means: notice the new version on the
/// website, download the APK in the background, verify it is a real archive,
/// then open the installer. The user confirms once and the app is replaced and
/// restarted — no store, no browser, no searching for the file.
class UpdateInfo {
  final String version;
  final bool mandatory;
  final List<int>? apkBytes;
  final String apkUrl;
  final String? apkSha256;
  final String notes;

  UpdateInfo({
    required this.version,
    this.mandatory = false,
    required this.apkUrl,
    this.apkBytes,
    this.apkSha256,
    required this.notes,
  });
}

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

  /// Validates that [hash] is a proper SHA-256 hex string (64 chars).
  static bool isValidSha256(String hash) {
    final normalized = hash.trim().toLowerCase();
    return RegExp(r'^[0-9a-f]{64}$').hasMatch(normalized);
  }

  /// Resolves an APK URL relative to the base host. Returns null when the URL
  /// points outside the permitted host or contains suspicious schemes.
  static String? _resolvedUrl(String rawUrl) {
    if (rawUrl.isEmpty) return null;
    try {
      final uri = Uri.parse(rawUrl);
      final host = Uri.parse(_base()).host;
      if (uri.host != host && uri.host != 'localhost' && uri.host != '10.0.2.2') return null;
      if (['http', 'https'].contains(uri.scheme)) return rawUrl;
    } catch (_) {
      return null;
    }
    return null;
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

      final rawUrl = (data['apk_url'] ?? '').toString();
      final serverHash = (data['sha256'] ?? data['apk_sha256'] ?? '').toString().trim().toLowerCase();
      if (!isValidSha256(serverHash)) {
        debugPrint('Update metadata missing or malformed SHA-256.');
        return null;
      }

      final url = _resolvedUrl(rawUrl);
      if (url == null) {
        debugPrint('Update APK URL rejected.');
        return null;
      }

      final summary = await http.readBytes(Uri.parse(url))
          .timeout(const Duration(seconds: 240), onTimeout: () => throw Exception('timeout'));
      final computed = sha256.convert(summary).toString().toLowerCase();
      if (computed != serverHash) {
        debugPrint('Update APK SHA-256 mismatch: expected $serverHash, got $computed.');
        return null;
      }

      return UpdateInfo(
        version: latest,
        apkBytes: summary,
        apkUrl: url,
        apkSha256: serverHash,
        notes: (data['whats_new'] ?? '').toString().trim(),
      );
    } catch (e) {
      debugPrint('Update check failed: $e');
      return null;
    }
  }

  /// Downloads the release APK to a temporary file. The caller must have the
  /// metadata; this path is used only for explicit UI downloads (the banner's
  /// Update Now action), which already validated that the metadata is present.
  static Future<File?> download(
    UpdateInfo info, {
    required void Function(double) onProgress,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/camanime-update.apk');
    if (await file.exists()) await file.delete();
    final sink = file.openWrite();
    var received = 0;
    final total = info.apkBytes?.length ?? 0;
    if (total > 0) {
      for (var chunk = 0; chunk < info.apkBytes!.length; chunk += 64 * 1024) {
        final end = (chunk + 64 * 1024).clamp(0, total);
        sink.write(info.apkBytes!.sublist(chunk, end));
        received = end;
        onProgress(received / total);
      }
    }
    await sink.close();
    onProgress(1.0);

    if (file.existsSync() && info.apkSha256 != null && !isValidSha256(info.apkSha256!)) {
      debugPrint('download() called without a verified SHA-256; aborting.');
      await file.delete();
      return null;
    }
    if (file.existsSync()) {
      final computed = sha256.convert(await file.readAsBytes()).toString().toLowerCase();
      if (computed != info.apkSha256) {
        debugPrint('Download SHA-256 mismatch: expected ${info.apkSha256}, got $computed.');
        await file.delete();
        return null;
      }
    }
    return file;
  }

  /// Sends the APK to the system installer. Returns false when Android needs
  /// "install unknown apps" enabled first (that screen is opened for the user).
  static Future<bool> install(File apk) async {
    if (!Platform.isAndroid) return false;
    if (!await apk.exists()) return false;
    try {
      return await _channel.invokeMethod<bool>('install', {'path': apk.path}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> canInstall() async {
    if (!Platform.isAndroid) return true;
    try {
      final result = await _channel.invokeMethod<bool>('canInstall') ?? true;
      return result;
    } catch (_) {
      return true;
    }
  }

  static Future<void> openPermissionSettings() async {
    try {
      await _channel.invokeMethod<bool>('permissionSettings');
    } catch (_) {}
  }

  /// Replaces this process with the freshly installed app. Android will keep
  /// this process alive briefly while the package installer finishes, so the
  /// restart is requested but not guaranteed to be immediate.
  static Future<void> restart() async {
    try {
      await _channel.invokeMethod<bool>('restart');
    } catch (_) {}
  }

  /// Shows a modal dialog with the given [widget] as its content.
  static Route dialogRoute(Widget widget) {
    return PageRouteBuilder(
      pageBuilder: (context, animation, secondaryAnimation) => widget,
      transitionDuration: const Duration(milliseconds: 200),
      transitionsBuilder: (context, animation, secondaryAnimation, child) => child,
    );
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

  /// Key used by [startUpdateNow] to dismiss the in-app update banner / dialog
  /// again after the freshly installed app comes back up. The native side calls
  /// this from [UpdaterBridge.restart] so the update notice is cleared in the
  /// same process that showed it.
  static const String _kUpdateDoneMethod = 'updateDone';

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

    var ok = await AppUpdater.canInstall();
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
    UpdateState.progress.value = 0.0;

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

    // Dismiss the in-app update notice in the same process that showed it, so
    // the banner / "Live update going on" heads-up does not linger after the
    // app has restarted into the newly installed build.
    _notifyUpdateDone(info.version);

    // Restart into the newly installed app.
    await restart();
  }

  /// Clears the "Live update going on" heads-up notification and the in-app
  /// update-available banner on this device after a successful install.
  ///
  /// Safe to call even when no update is currently in flight — the native side
  /// is a no-op for an empty version, and the Dart side is guarded by
  /// [mounted].
  static Future<void> _notifyUpdateDone(String version) async {
    try {
      await _channel.invokeMethod<void>(_kUpdateDoneMethod, {'version': version});
    } catch (_) {}
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
