import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_updater.dart';
import 'cam_ui.dart';
import 'models.dart' show apiHost;

/// Build identity reported to the server. Kept here so the gate has no
/// dependency on the UI layer (and no import cycle through main.dart).
const String kAppVersion = '2.14.0';
const int kAppBuildNumber = 26;

/// Server-driven release policy.
///
/// The server owns the numbers; the app only reports its own build and obeys
/// the answer. Everything here is a convenience for the user — the actual
/// enforcement lives in `before_request` on the backend, so removing or editing
/// this file in a rebuilt APK does not unlock streaming.
class VersionPolicy {
  final String latestVersion;
  final int latestVersionCode;
  final String minimumVersion;
  final int minimumVersionCode;
  final bool forceUpdate;
  final String downloadUrl;
  final String message;
  final String releaseNotes;

  /// True when the server has retired this release outright (2.6.5 and older),
  /// which is a stronger message than "outdated".
  final bool discontinued;
  final String discontinuedVersion;

  /// Official mirror (Cloudflare) shown beside the primary download link, so a
  /// device is never stranded when one host is unreachable.
  final String mirrorDownloadUrl;
  final String reason;

  const VersionPolicy({
    required this.latestVersion,
    required this.latestVersionCode,
    required this.minimumVersion,
    required this.minimumVersionCode,
    required this.forceUpdate,
    required this.downloadUrl,
    required this.message,
    required this.releaseNotes,
    this.discontinued = false,
    this.discontinuedVersion = '',
    this.mirrorDownloadUrl = '',
    this.reason = '',
  });

  static VersionPolicy? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    int asInt(dynamic v) => v is int ? v : int.tryParse('$v'.trim()) ?? 0;
    final latest = (json['latest_version'] ?? '').toString();
    final minimum = (json['minimum_supported_version'] ?? latest).toString();
    if (latest.isEmpty) return null;
    return VersionPolicy(
      latestVersion: latest,
      latestVersionCode: asInt(json['latest_version_code']),
      minimumVersion: minimum,
      minimumVersionCode: asInt(json['minimum_supported_version_code']),
      forceUpdate: json['force_update'] == true || json['force_update'] == 1,
      downloadUrl: (json['download_url'] ?? '').toString(),
      message: (json['message'] ?? '').toString(),
      releaseNotes: (json['release_notes'] ?? '').toString(),
      discontinued: json['discontinued'] == true || json['discontinued'] == 1,
      discontinuedVersion:
          (json['discontinued_at_or_below_version'] ?? '').toString(),
      mirrorDownloadUrl: ((json['download_urls'] as Map?)?['cloudflare'] ?? '')
          .toString(),
      reason: (json['reason'] ?? '').toString(),
    );
  }

  String get resolvedDownloadUrl {
    if (downloadUrl.isEmpty) return 'https://camanime.onrender.com/get/android';
    if (downloadUrl.startsWith('http')) return downloadUrl;
    final base = apiHost.replaceFirst(RegExp(r'/+$'), '');
    return '$base${downloadUrl.startsWith('/') ? '' : '/'}$downloadUrl';
  }

  String get resolvedMirrorUrl {
    if (mirrorDownloadUrl.isEmpty) return '';
    if (mirrorDownloadUrl.startsWith('http')) return mirrorDownloadUrl;
    final base = apiHost.replaceFirst(RegExp(r'/+$'), '');
    return '$base${mirrorDownloadUrl.startsWith('/') ? '' : '/'}$mirrorDownloadUrl';
  }
}

/// Reports this install to the server and exposes the blocking policy, if any.
class VersionGate {
  VersionGate._();

  /// Non-null when the server says this build may not use the app.
  static final ValueNotifier<VersionPolicy?> required = ValueNotifier(null);

  /// Last check outcome, for the retry state on the update screen.
  static final ValueNotifier<String?> lastError = ValueNotifier(null);
  static bool _checking = false;

  static String? _installId;

  static String _base() => apiHost.replaceFirst(RegExp(r'/+$'), '');

  /// Stable per-install identifier so outdated devices can be counted without
  /// collecting anything personal.
  static Future<String> installId() async {
    if (_installId != null) return _installId!;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('app_install_id');
    if (id == null || id.length < 12) {
      final rng = Random.secure();
      id = List.generate(16, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'))
          .join();
      await prefs.setString('app_install_id', id);
    }
    _installId = id;
    return id;
  }

  /// Headers every API request carries, so the server can enforce the policy
  /// without relying on the UI.
  static Future<Map<String, String>> headers() async {
    return {
      'X-CamAnime-Version': kAppVersion,
      'X-CamAnime-Build': '$kAppBuildNumber',
      'X-CamAnime-Platform': Platform.isAndroid ? 'android' : 'other',
      'X-CamAnime-Install': await installId(),
    };
  }

  /// Asks the server what this build is allowed to do.
  ///
  /// Returns true when an update is required. On network failure the previous
  /// state is kept so a flaky connection cannot strand, or unlock, the app:
  /// the blocking screen shows a retry, and the server still refuses the
  /// protected calls that matter.
  static Future<bool> check() async {
    if (_checking) return required.value != null;
    _checking = true;
    try {
      final res = await http
          .get(Uri.parse('${_base()}/api/app/ping?platform=${Platform.isAndroid ? 'android' : 'other'}'),
              headers: await headers())
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 426) {
        final body = json.decode(res.body) as Map<String, dynamic>;
        required.value = VersionPolicy.fromJson(
            (body['policy'] as Map?)?.cast<String, dynamic>() ?? body);
        lastError.value = null;
        return true;
      }
      if (res.statusCode != 200) {
        lastError.value = 'The update server answered ${res.statusCode}.';
        return required.value != null;
      }
      final body = json.decode(res.body) as Map<String, dynamic>;
      final policy = VersionPolicy.fromJson(
          (body['policy'] as Map?)?.cast<String, dynamic>());
      final needs = body['required'] == true;
      required.value = needs ? policy : null;
      lastError.value = null;
      return needs;
    } catch (_) {
      lastError.value = 'Could not reach the update server.';
      return required.value != null;
    } finally {
      _checking = false;
    }
  }

  /// Fire-and-forget check used at launch and on resume.
  static void refresh() {
    unawaited(check());
  }

  static void reset() {
    required.value = null;
    lastError.value = null;
  }
}

/// Blocking, non-dismissible update screen.
///
/// There is no "Later" and no back-out into the app: while this is on screen the
/// server refuses the protected calls anyway, so pretending the user can browse
/// would only produce confusing empty states.
class UpdateRequiredScreen extends StatefulWidget {
  final VersionPolicy policy;
  final String currentVersion;
  const UpdateRequiredScreen(
      {super.key, required this.policy, required this.currentVersion});

  @override
  State<UpdateRequiredScreen> createState() => _UpdateRequiredScreenState();
}

class _UpdateRequiredScreenState extends State<UpdateRequiredScreen> {
  bool busy = false;
  bool retrying = false;
  double? progress;

  Future<void> _updateNow() async {
    setState(() {
      busy = true;
      progress = null;
    });
    final info = UpdateInfo(
      version: widget.policy.latestVersion,
      apkUrl: widget.policy.resolvedDownloadUrl,
      apkBytes: null,
      notes: widget.policy.releaseNotes,
    );
    final file = await AppUpdater.download(info, onProgress: (p) {
      if (mounted) setState(() => progress = p);
    });
    if (!mounted) return;
    setState(() => busy = false);
    if (file == null) {
      _snack('The download failed. Tap Update Now to try again.');
      return;
    }
    var allowed = await AppUpdater.canInstall();
    if (!mounted) return;
    if (!allowed) {
      await AppUpdater.openPermissionSettings();
      if (!mounted) return;
      _snack('Allow installs for CamAnime, then tap Update Now again.');
      return;
    }
    final started = await AppUpdater.install(file);
    if (!mounted) return;
    _snack(started
        ? 'Confirm the install to finish CamAnime ${widget.policy.latestVersion}.'
        : 'Android blocked the installer. Allow unknown sources and retry.');
  }

  Future<void> _openLink(String url) async {
    try {
      final ok = await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
      if (!ok) _snack('Open camanime.onrender.com in your browser to download.');
    } catch (_) {
      _snack('Open camanime.onrender.com in your browser to download.');
    }
  }

  Future<void> _openWebsite() => _openLink(
      widget.policy.downloadUrl.startsWith('http')
          ? widget.policy.resolvedDownloadUrl
          : 'https://camanime.onrender.com/get/android');

  Future<void> _openMirror() => _openLink(widget.policy.resolvedMirrorUrl);

  Future<void> _retry() async {
    setState(() => retrying = true);
    final needs = await VersionGate.check();
    if (!mounted) return;
    setState(() => retrying = false);
    if (!needs) {
      _snack('Access restored. You are on a supported version.');
    } else {
      _snack(VersionGate.lastError.value ?? 'Still out of date.');
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.policy;
    return Scaffold(
      backgroundColor: CamColors.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 92,
                    height: 92,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                          colors: [CamColors.accent, CamColors.accent.withValues(alpha: .45)]),
                    ),
                    child: const Icon(Icons.play_arrow_rounded,
                        size: 52, color: Colors.black),
                  ),
                  const SizedBox(height: 18),
                  const Text('CamAnime',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -.5)),
                  const SizedBox(height: 26),
                  Text(p.discontinued ? 'Version Discontinued' : 'Update Required',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: Theme.of(context).colorScheme.primary)),
                  const SizedBox(height: 10),
                  Text(
                    p.message.isEmpty
                        ? 'This version can no longer stream or download anime. '
                            'Install the latest CamAnime from the official website to continue.'
                        : p.message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: CamColors.inkDim, height: 1.5, fontSize: 13),
                  ),
                  const SizedBox(height: 22),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                        color: CamColors.surfaceAlt,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: CamColors.line)),
                    child: Column(children: [
                      _row('Installed', widget.currentVersion),
                      const SizedBox(height: 8),
                      _row('Latest', p.latestVersion, highlight: true),
                      const SizedBox(height: 8),
                      _row('Required minimum', p.minimumVersion),
                    ]),
                  ),
                  if (p.releaseNotes.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(p.releaseNotes,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: CamColors.inkDim, fontSize: 12, height: 1.5)),
                  ],
                  const SizedBox(height: 22),
                  if (busy) ...[
                    LinearProgressIndicator(
                        value: progress,
                        backgroundColor: CamColors.line,
                        valueColor: AlwaysStoppedAnimation(CamColors.accent)),
                    const SizedBox(height: 8),
                    Text(
                        progress == null
                            ? 'Preparing download…'
                            : '${(progress! * 100).toStringAsFixed(0)}%',
                        textAlign: TextAlign.center,
                        style:
                            const TextStyle(color: CamColors.inkDim, fontSize: 12)),
                    const SizedBox(height: 10),
                  ],
                  FilledButton.icon(
                    onPressed: busy ? null : _updateNow,
                    icon: const Icon(Icons.system_update_rounded),
                    label: Text(busy ? 'Downloading…' : 'Update Now'),
                    style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        textStyle: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w800)),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _openWebsite,
                    icon: const Icon(Icons.open_in_new_rounded, size: 18),
                    label: const Text('Official website'),
                  ),
                  if (p.resolvedMirrorUrl.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _openMirror,
                      icon: const Icon(Icons.cloud_download_rounded, size: 18),
                      label: const Text('Cloudflare mirror'),
                    ),
                  ],
                  const SizedBox(height: 6),
                  TextButton(
                    onPressed: (busy || retrying) ? null : _retry,
                    child: Text(retrying
                        ? 'Checking…'
                        : 'Retry version check'),
                  ),
                  if (VersionGate.lastError.value != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(VersionGate.lastError.value!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: CamColors.inkDim, fontSize: 11.5)),
                    ),
                  const SizedBox(height: 18),
                  const Text(
                    'Enforced by the CamAnime server. Installing keeps your '
                    'library, downloads and watch history.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: CamColors.inkDim, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(String label, String value, {bool highlight = false}) {
    return Row(children: [
      Text(label,
          style: const TextStyle(color: CamColors.inkDim, fontSize: 12.5)),
      const Spacer(),
      Text(value,
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: highlight
                  ? Theme.of(context).colorScheme.primary
                  : CamColors.ink)),
    ]);
  }
}
