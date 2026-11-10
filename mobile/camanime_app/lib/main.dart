import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'core/ad_notifications.dart';
import 'core/app_updater.dart';
import 'core/version_gate.dart';
import 'core/app_notifications.dart';
import 'core/app_config.dart';
import 'core/firebase_boot.dart';
import 'core/push.dart';
import 'core/cam_ui.dart';
import 'core/downloads.dart';
import 'core/mini_player.dart';
import 'core/models.dart';
import 'core/watchlist.dart';
import 'core/pip.dart';
import 'screens/library_screen.dart';
import 'screens/player_screen.dart';
import 'screens/settings_screen.dart';
import 'widgets/episode_board.dart';

// ── Release line ───────────────────────────────────────
const String appVersion = '2.10.0';
const String appCredit = 'Made by kayefande-droid & co.';

// ── Website-mirrored palette ───────────────────────────
const bg = Color(0xFF07080D);
const card = Color(0xFF0E111A);
const card2 = Color(0xFF141926);
const amber = Color(0xFFFFB347);
const pink = Color(0xFFFF5E62);
const purple = Color(0xFF7C61D4);
const mint = Color(0xFF10B981);
const muted = Color(0xFFA0ABC0);
const brandBlue = Color(0xFF087BFF);
const brandCyan = Color(0xFF04DEE8);
const brandPurple = Color(0xFF8635EF);

// ── App themes (Settings → Appearance) ─────────────────
const Map<String, Map<String, dynamic>> appThemes = {
  'midnight': {'label': 'Midnight', 'seed': 0xFF087BFF, 'bg': 0xFF07080D},
  'vibrant': {'label': 'Vibrant', 'seed': 0xFF7C61D4, 'bg': 0xFF14101F},
  'sakura': {'label': 'Sakura', 'seed': 0xFFFF7AA8, 'bg': 0xFF120A12},
  'forest': {'label': 'Forest', 'seed': 0xFF34D399, 'bg': 0xFF07120E},
  'neon': {'label': 'Neon', 'seed': 0xFF00E5FF, 'bg': 0xFF05090F},
  'ocean': {'label': 'Ocean', 'seed': 0xFF22D3EE, 'bg': 0xFF04121A},
  'sunset': {'label': 'Sunset', 'seed': 0xFFFF8A3D, 'bg': 0xFF160B06},
  'mono': {'label': 'Mono', 'seed': 0xFFE5E7EB, 'bg': 0xFF0A0A0B},
};

const List<Map<String, dynamic>> avatarPresets = [
  {'icon': IconData(0xe491), 'color': 0xFFFFB347}, // person
  {'icon': IconData(0xe3b6), 'color': 0xFFFF5E62}, // movie
  {'icon': IconData(0xe40d), 'color': 0xFF7C61D4}, // bolt
  {'icon': IconData(0xe1d2), 'color': 0xFF10B981}, // star
  {'icon': IconData(0xe0e5), 'color': 0xFF04DEE8}, // rocket
  {'icon': IconData(0xe1fe), 'color': 0xFFFF7AA8}, // pets
  {'icon': IconData(0xe1a3), 'color': 0xFF087BFF}, // sports
  {'icon': IconData(0xe548), 'color': 0xFFA3E635}, // game
];

// ── App modes ──────────────────────────────────────────
class AppMode {
  static const String stream = 'stream';
  static const String download = 'download';
  static const List<String> all = [stream, download];

  static Future<String> get() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString('app_mode');
    return saved == download ? download : stream;
  }

  static Future<void> set(String mode) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('app_mode', mode == download ? download : stream);
  }
}

/// Global mode holder. Switching modes rebuilds the whole UI tree, which the
/// user experiences as an app restart landing them in the requested mode.
final ValueNotifier<String> appMode = ValueNotifier<String>(AppMode.stream);



void _openAdvertFromNotification(String animeId, String title) {
  if (animeId.isEmpty) return;
  final navigator = appNavigatorKey.currentState;
  if (navigator == null) {
    Timer(const Duration(milliseconds: 600),
        () => _openAdvertFromNotification(animeId, title));
    return;
  }
  navigator.push(MaterialPageRoute(
      builder: (_) => DetailScreen(
          animeId: animeId, title: title.isEmpty ? 'Anime' : title)));
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Installed before runApp so a push delivered during launch is handled.
  PushService.registerBackgroundHandler();
  // Firebase must be ready before Firebase Messaging is used. A broken config
  // leaves `FirebaseBoot.ready == false` and the app still launches.
  await FirebaseBoot.init();
  DownloadManager.instance.headersProvider = Api.headers;
  appMode.value = await AppMode.get();

  // Draw the first frame first. Reading the download queue and scanning the
  // legacy library is disk work; awaiting it before runApp delayed the first
  // frame long enough for Android to show "CamAnime isn't responding" on a
  // cold start with a full library or a slow flash. The Library listens to
  // the manager, so restored downloads appear as soon as the scan finishes.
  runApp(const CamAnimeApp());
  unawaited(DownloadManager.instance.init());
  // Start/stop the Android advert schedule and catch notification taps.
  unawaited(AdNotifications.init(onOpen: _openAdvertFromNotification));
  // Heads-up alerts for finished downloads (Android 13+ permission included).
  unawaited(AppNotifications.init());
  // Wake the API host early so the first catalogue request is not the one
  // paying for a cold start.
  unawaited(Api.warmup());
  // Ask the server whether this build may still use protected services.
  unawaited(VersionGate.check());
  // Server-owned banners, maintenance mode and feature switches.
  unawaited(RemoteConfig.refresh());
  // FCM registration. A build with no Firebase config simply stays quiet.
  unawaited(PushService.init());
  // Honor a notification tap or the scheduled two-minute alarm that asks the app
  // to start the live update now.
  unawaited(() async {
    try {
      const updateCh = MethodChannel('camanime/update');
      updateCh.setMethodCallHandler((call) async {
        if (call.method == 'startNow') {
          await AppUpdater.startUpdateNow();
          return null;
        }
        throw MissingPluginException();
      });
    } catch (_) {}
  }());
}

class CamAnimeApp extends StatefulWidget {
  const CamAnimeApp({super.key});
  @override
  State<CamAnimeApp> createState() => _CamAnimeAppState();
}

class _CamAnimeAppState extends State<CamAnimeApp> with WidgetsBindingObserver {
  int tab = 0;
  bool showTutorial = false;
  String themeName = 'midnight';
  /// Set when an update check finds a newer build, so the app can show an
  /// in-app update-available notice without waiting for the download dialog.
  String? updateAvailable;

  static const _tabs = [
    ('Home', Icons.home_outlined, Icons.home),
    ('Explore', Icons.explore_outlined, Icons.explore),
    ('Search', Icons.search_outlined, Icons.search),
    ('Library', Icons.video_library_outlined, Icons.video_library),
    ('Profile', Icons.person_outline, Icons.person),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Closing the floating window (Android's X) ends mini playback instead of
    // leaving an orphaned decoder running.
    PiP.listen((inPip) {
      if (!inPip && MiniPlayer.current.value != null) {
        unawaited(MiniPlayer.close());
      }
    });
    // A notification tap can arrive before the first frame is up, so the link
    // is kept in the service and drained here once navigation exists.
    PushService.pendingLink.addListener(_openPendingPushLink);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openPendingPushLink());
    _firstRun();
  }

  /// Opens the anime/episode carried by a tapped push notification.
  /// Only `/watch/<id>/<ep>` and `/anime/<id>` are accepted; anything else is
  /// dropped rather than fed to the router.
  void _openPendingPushLink() {
    final link = PushService.pendingLink.value;
    if (link == null || link.isEmpty || !mounted) return;
    PushService.pendingLink.value = null;
    final parts = Uri.tryParse(link)?.pathSegments ?? const <String>[];
    if (parts.length < 2) return;
    if (parts[0] != 'watch' && parts[0] != 'anime') return;
    final id = parts[1];
    if (id.isEmpty) return;
    appNavigatorKey.currentState?.push(MaterialPageRoute(
        builder: (_) => DetailScreen(animeId: id, title: 'Anime')));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Returning to the foreground is the moment a stalled download or a cold
    // API host can be retried, on WiFi or mobile data alike.
    unawaited(DownloadManager.instance.kick());
    unawaited(Api.warmup());
    unawaited(VersionGate.check());
    unawaited(RemoteConfig.refresh());
    unawaited(PushService.init());
    unawaited(_autoCheckUpdate());
  }

  @override
  void dispose() {
    PushService.pendingLink.removeListener(_openPendingPushLink);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _firstRun() async {
    final p = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        themeName = appThemes.containsKey(p.getString('app_theme'))
            ? p.getString('app_theme')!
            : 'midnight';
      });
    }
    if (p.getBool('tutorial_done') != true) {
      if (mounted) setState(() => showTutorial = true);
    }
    await _showWhatsNewIfNeeded();
    _autoCheckUpdate();
  }

  Future<void> _showWhatsNewIfNeeded() async {
    final w = await AppUpdater.whatsNew();
    if (!w.show || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: card,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 6,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0x1A087BFF),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.info_outline, size: 18, color: const Color(0xFF087BFF)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('CamAnime ${w.version}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text('What is new', style: TextStyle(fontSize: 11.5, color: muted, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ],
          ),
          content: Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text(
              w.notes.trim().isEmpty
                  ? 'We tightened up the app behind the scenes. Your library and downloads are unchanged.'
                  : w.notes,
              style: const TextStyle(color: muted, fontSize: 12.5, height: 1.55),
            ),
          ),
          actions: [
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF087BFF),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () {
                Navigator.of(context, rootNavigator: true).pop();
              },
              child: const Text('Continue'),
            ),
          ],
        ),
      );
    });
  }

  /// Launch/resume update check, throttled to once every six hours so opening
  /// the app repeatedly does not hammer the host. Manual checks bypass this.
  Future<void> _autoCheckUpdate() async {
    try {
      final p = await SharedPreferences.getInstance();
      final last = p.getInt('update_checked_at') ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - last < const Duration(hours: 6).inMilliseconds) return;
      await p.setInt('update_checked_at', now);
    } catch (_) {}
    await _checkUpdate();
  }

  /// Checks the website on launch and, when a newer build exists, downloads and
  /// installs it without the user going to a browser.
  ///
  /// When a newer build is found the app posts a "Live update going on"
  /// heads-up notification (via the existing announcement channel) so the user sees
  /// the update even when the download dialog is behind another app, and shows an
  /// in-app update-available notice for manual checks.
  Future<void> _checkUpdate({bool manual = false}) async {
    final installed = await AppUpdater.installedVersion();
    final info = await AppUpdater.check(current: installed);
    if (!mounted) return;
    if (info == null) {
      if (manual) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('You are on the latest version ($installed)')));
      }
      return;
    }
    // Alert the user that an update is happening / available.
    if (mounted) {
      unawaited(AppNotifications.updateInProgress(info.version));
    }
    if (manual) {
      if (mounted) {
        setState(() => updateAvailable = info.version);
      }
    }
    await _installUpdate(info);
  }

  /// Downloads the new APK with a live progress sheet, then opens the system
  /// installer. Android replaces the app and restarts it after the install.
  Future<void> _installUpdate(UpdateInfo info) async {
    if (!Platform.isAndroid) {
      _updateDialog(info.version);
      return;
    }
    var allow = await AppUpdater.canInstall();
    if (!mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: card,
        title: Text('Updating to CamAnime ${info.version}'),
        content: Text(
            'The new version is downloading and will install itself. Your '
            'library, downloads and watch history stay exactly as they are — an '
            'update replaces the app, never your files. If Android asks to allow '
            'installs from CamAnime, accept once.'
            '${allow ? '' : '\n\nTap Continue to enable that permission.'}'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Later')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: amber, foregroundColor: Colors.black),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(allow ? 'Update now' : 'Continue'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    if (!allow) {
      await AppUpdater.openPermissionSettings();
      return;
    }

    final progress = ValueNotifier<double?>(0);
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => ValueListenableBuilder<double?>(
        valueListenable: progress,
        builder: (c, value, _) => AlertDialog(
          backgroundColor: card,
          title: Text('Downloading ${info.version}'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            LinearProgressIndicator(
              value: value,
              backgroundColor: CamColors.line,
              valueColor: const AlwaysStoppedAnimation<Color>(amber),
            ),
            const SizedBox(height: 12),
            Text(value == null
                ? 'Starting…'
                : '${(value * 100).toStringAsFixed(0)}%'),
          ]),
        ),
      ),
    );

    final apk = await AppUpdater.download(
      info,
      onProgress: (p) => progress.value = p,
    );
    progress.dispose();
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    if (apk == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Update download failed. Try again from Settings → Check for updates.')));
      return;
    }
    final started = await AppUpdater.install(apk);
    if (!mounted) return;
    if (!started) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Allow installs for CamAnime in the settings screen that opened, '
              'then tap Check for updates again.')));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text('Confirm the install to finish CamAnime ${info.version}.')));
  }

  void _updateDialog(String latest) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: card,
        title: Text('Update available: $latest'),
        content: const Text(
            'A newer CamAnime is on the website. Download it now? Watching stays free, no login needed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Later')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: amber, foregroundColor: Colors.black),
            onPressed: () {
              Navigator.pop(context);
              _checkUpdate(manual: true);
            },
            child: const Text('Get it'),
          ),
        ],
      ),
    );
  }

  Future<void> _applyTheme(String name) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('app_theme', name);
    if (mounted) setState(() => themeName = name);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      // Re-keying the tree on each mode switch rebuilds every screen, tab and
      // pushed route fresh, so the user genuinely lands in the requested mode.
      valueListenable: appMode,
      builder: (_, String mode, __) => _buildApp(mode),
    );
  }

  Widget _buildApp(String mode) {
    final t = appThemes[themeName] ?? appThemes['midnight']!;
    final seed = Color(t['seed'] as int);
    final scaffold = Color(t['bg'] as int);
    return MaterialApp(
      key: ValueKey('app-$mode'),
      title: 'CamAnime',
      debugShowCheckedModeBanner: false,
      navigatorKey: appNavigatorKey,
      theme: camTheme(seed: seed, background: scaffold),
      home: ValueListenableBuilder<VersionPolicy?>(
        valueListenable: VersionGate.required,
        builder: (_, requiredPolicy, __) {
          // A server-flagged build gets no tabs, no routes and no dismiss: the
          // backend refuses protected calls anyway, and a half-working app
          // would only look broken.
          if (requiredPolicy != null) {
            return UpdateRequiredScreen(
                policy: requiredPolicy, currentVersion: appVersion);
          }
          return Stack(
            children: [
              Scaffold(
                body: [
                  HomeTab(onUpdate: () => _checkUpdate(manual: true)),
                  const ExploreTab(),
                  const SearchTab(),
                  const LibraryTab(),
                  const ProfileTab(),
                ][tab],
                bottomNavigationBar: _FloatingNav(
                  tab: tab,
                  tabs: _tabs,
                  onTab: (i) => setState(() => tab = i),
                  onSettings: () async {
                    final nav = appNavigatorKey.currentState;
                    if (nav == null) return;
                    await nav.push(MaterialPageRoute(
                        builder: (_) => SettingsScreen(
                            themeName: themeName,
                            onTheme: _applyTheme,
                            version: appVersion,
                            credit: appCredit,
                            themes: appThemes,
                            onReplayTour: () =>
                                setState(() => showTutorial = true),
                            onCheckUpdate: () => _checkUpdate(manual: true))));
                  },
                  onNotifications: () async {
                    final nav = appNavigatorKey.currentState;
                    if (nav == null) return;
                    await nav.push(MaterialPageRoute(
                        builder: (_) => const NotificationBellScreen()));
                  },
                ),
              ),
              const Positioned(
                  left: 12, right: 12, bottom: 88, child: _MiniBar()),
              if (showTutorial)
                TutorialOverlay(onDone: () async {
                  final p = await SharedPreferences.getInstance();
                  await p.setBool('tutorial_done', true);
                  setState(() => showTutorial = false);
                  _checkUpdate();
                }),
              if (updateAvailable != null)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 88,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () async {
                        setState(() => updateAvailable = null);
                        await _checkUpdate(manual: true);
                      },
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: amber,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.system_update, size: 20,
                                color: Colors.black),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Update available: $updateAvailable — tap to update now.',
                                style: const TextStyle(
                                    color: Colors.black, fontWeight: FontWeight.w600),
                              ),
                            ),
                            const Icon(Icons.arrow_forward, size: 20,
                                color: Colors.black),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

// ── Miniplayer bar ─────────────────────────────────────
/// Sits above the nav whenever an episode is playing outside the player screen.
class _MiniBar extends StatelessWidget {
  const _MiniBar();

  String _clock(Duration d) {
    final total = d.inSeconds;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([MiniPlayer.current, MiniPlayer.tick]),
      builder: (context, _) {
        final live = MiniPlayer.current.value;
        if (live == null) return const SizedBox.shrink();
        final value = live.controller.value;
        final total = value.duration.inMilliseconds;
        final pos = value.position.inMilliseconds.clamp(0, total).toDouble();
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () async {
              // Hand the very same controller to the full player: no reload, no
              // re-buffer, and the position is preserved exactly.
              final detached = MiniPlayer.detach();
              final rebuild = detached?.rebuild;
              if (detached == null || rebuild == null) return;
              if (!context.mounted) return;
              Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => rebuild(detached)));
            },
            child: Container(
              decoration: BoxDecoration(
                color: CamColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: CamColors.line),
                boxShadow: const [
                  BoxShadow(
                      color: Color(0xA6000000),
                      blurRadius: 20,
                      offset: Offset(0, 6)),
                ],
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 9, 6, 9),
                  child: Row(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 44,
                        height: 44,
                        child: live.image.isEmpty
                            ? Container(
                                color: CamColors.surfaceAlt,
                                alignment: Alignment.center,
                                child: const Icon(Icons.movie_rounded,
                                    size: 18, color: CamColors.inkDim))
                            : Image.network(live.image,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Container(
                                      color: CamColors.surfaceAlt,
                                      alignment: Alignment.center,
                                      child: const Icon(Icons.movie_rounded,
                                          size: 18, color: CamColors.inkDim),
                                    )),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(live.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w800)),
                            const SizedBox(height: 2),
                            Text(
                              '${live.subtitle} · ${_clock(value.position)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: CamColors.inkDim, fontSize: 10.5),
                            ),
                          ]),
                    ),
                    IconButton(
                      tooltip: 'Back 10 seconds',
                      visualDensity: VisualDensity.compact,
                      onPressed: () =>
                          MiniPlayer.seekBy(const Duration(seconds: -10)),
                      icon: const Icon(Icons.replay_10_rounded,
                          size: 21, color: CamColors.inkDim),
                    ),
                    IconButton(
                      tooltip: value.isPlaying ? 'Pause' : 'Play',
                      onPressed: MiniPlayer.toggle,
                      icon: Icon(
                        value.isPlaying
                            ? Icons.pause_circle_filled_rounded
                            : Icons.play_circle_fill_rounded,
                        size: 30,
                        color: CamColors.accent,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Forward 10 seconds',
                      visualDensity: VisualDensity.compact,
                      onPressed: () =>
                          MiniPlayer.seekBy(const Duration(seconds: 10)),
                      icon: const Icon(Icons.forward_10_rounded,
                          size: 21, color: CamColors.inkDim),
                    ),
                    IconButton(
                      tooltip: 'Close miniplayer',
                      visualDensity: VisualDensity.compact,
                      onPressed: MiniPlayer.close,
                      icon: const Icon(Icons.close_rounded,
                          size: 18, color: CamColors.inkDim),
                    ),
                  ]),
                ),
                ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(bottom: Radius.circular(16)),
                  child: LinearProgressIndicator(
                    value: total <= 0 ? 0 : (pos / total).clamp(0.0, 1.0),
                    minHeight: 2.5,
                    backgroundColor: CamColors.surfaceAlt,
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(CamColors.accent),
                  ),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }
}

// ── Floating bottom navigation + gear ──────────────────
class _FloatingNav extends StatelessWidget {
  final int tab;
  final List<(String, IconData, IconData)> tabs;
  final ValueChanged<int> onTab;
  final VoidCallback onSettings;
  final VoidCallback onNotifications;
  const _FloatingNav(
      {required this.tab,
      required this.tabs,
      required this.onTab,
      required this.onSettings,
      required this.onNotifications});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xF20A0D14),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: CamColors.line),
            boxShadow: const [
              BoxShadow(
                  color: Color(0xA6000000),
                  blurRadius: 26,
                  offset: Offset(0, 12))
            ],
          ),
          child: Row(children: [
            for (var i = 0; i < tabs.length; i++)
              Expanded(child: _item(i, accent)),
            Container(
              width: 1,
              height: 24,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              color: CamColors.line,
            ),
            // Notification bell: shows a badge when there are unread announcements.
            _BellButton(
              onPressed: onNotifications,
              color: accent,
            ),
            IconButton(
              tooltip: 'App settings',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.settings_outlined,
                  size: 22, color: CamColors.inkDim),
              onPressed: onSettings,
            ),
          ]),
        ),
      ),
    );
  }

  Widget _item(int i, Color accent) {
    final selected = tab == i;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => onTab(i),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: selected
              ? LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    accent.withValues(alpha: 0.24),
                    accent.withValues(alpha: 0.04),
                  ],
                )
              : null,
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(selected ? tabs[i].$3 : tabs[i].$2,
              size: 22, color: selected ? accent : CamColors.inkDim),
          const SizedBox(height: 3),
          Text(tabs[i].$1,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.1,
                  color: selected ? accent : CamColors.inkDim)),
        ]),
      ),
    );
  }
}

/// Notification bell with unread badge.
class _BellButton extends StatefulWidget {
  final VoidCallback onPressed;
  final Color color;
  const _BellButton({required this.onPressed, required this.color});

  @override
  State<_BellButton> createState() => _BellButtonState();
}

class _BellButtonState extends State<_BellButton> {
  int _count = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final data = await Api.announcements();
      final list = (data['announcements'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      // Count unread: an announcement is unread until the user opens the
      // notification bell; for simplicity we treat everything as unread until
      // the bell is opened.
      final seenIds = await _seenIds();
      final unseen = list.where((item) {
        return !seenIds.contains(item['id']?.toString() ?? '');
      }).toList();
      if (!mounted) return;
      setState(() {
        _count = unseen.length;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _count = 0;
      });
    }
  }

  Future<Set<String>> _seenIds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList('seen_announcement_ids') ?? <String>[]).toSet();
  }

  @override
  Widget build(BuildContext context) {
    final showBadge = _count > 0;
    return InkWell(
      onTap: widget.onPressed,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: widget.color.withValues(alpha: 0.15),
          shape: BoxShape.circle,
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(Icons.notifications_outlined,
                size: 22, color: widget.color),
            if (showBadge || _loading)
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                  constraints: const BoxConstraints(
                    minWidth: 16,
                    minHeight: 16,
                  ),
                  child: Text(
                    _loading ? '?' : (_count > 99 ? '99+' : '$_count'),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── API (the CamAnime website — always connected) ───────
class Api {
  // Hardwired to the website backend. No manual URL entry anywhere.
  static String base() => apiHost.replaceFirst(RegExp(r'/+$'), '');

  static String abs(String url) =>
      url.startsWith('http') ? url : '${base()}$url';

  static bool isPlayableVideoType(String contentType) {
    final value = contentType.toLowerCase().split(';').first.trim();
    return value.startsWith('video/') ||
        value == 'application/octet-stream' ||
        value == 'application/mp4';
  }

  static String safeMediaFilename(String filename) {
    final leaf = filename.replaceAll('\\', '/').split('/').last;
    final safe = leaf.replaceAll(RegExp(r'[^a-zA-Z0-9_\-. ]'), '').trim();
    if (safe.isEmpty || safe == '.' || safe == '..') {
      return 'CamAnime_Episode.mp4';
    }
    return safe;
  }

  static Future<String?> token() async {
    final p = await SharedPreferences.getInstance();
    return p.getString('api_token');
  }

  static Future<Map<String, String>> headers() async {
    final t = await token();
    return {
      if (t != null) 'Authorization': 'Bearer $t',
      // Version identity on every API call: the server enforces the minimum
      // build itself, so hiding the update screen in a rebuilt app changes
      // nothing about what the backend allows.
      ...await VersionGate.headers(),
    };
  }

  static Future<String> guestName() async {
    final p = await SharedPreferences.getInstance();
    return (p.getString('username') ?? '').trim();
  }

  static Future<int> avatarIdx() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt('avatar_idx') ?? 0;
  }

  /// One pooled client for every JSON call the app makes. Keeping it alive
  /// saves a DNS lookup and TLS handshake per request, which is what makes
  /// tab switches feel instant on a good network.
  static http.Client? _sharedClient;
  static http.Client _client() => _sharedClient ??= IOClient(HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..idleTimeout = const Duration(seconds: 25)
    ..maxConnectionsPerHost = 8);

  /// Fire-and-forget ping used at launch and on resume.
  static Future<void> warmup() async {
    try {
      await _get(Uri.parse('${base()}/api/version'),
          timeout: const Duration(seconds: 12));
    } catch (_) {
      // Nothing to do: the next real request retries anyway.
    }
  }

  static bool _isTransientStatus(int status) =>
      status == 408 || status == 429 || status >= 500;
  static const bool _testMode = bool.fromEnvironment('FLUTTER_TEST');

  static Future<http.Response> _get(Uri uri,
      {Duration timeout = const Duration(seconds: 20)}) async {
    Object? lastError;
    final attempts = _testMode ? 1 : 3;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        final response = await _client().get(uri).timeout(timeout);
        if (_isTransientStatus(response.statusCode) && attempt + 1 < attempts) {
          // 300ms, 600ms, 1.2s: covers a Render cold start or a brief 429
          // without making a genuinely offline app wait for the full ladder.
          await Future<void>.delayed(
              Duration(milliseconds: 300 * (1 << attempt)));
          continue;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw HttpException('Server returned ${response.statusCode}',
              uri: uri);
        }
        return response;
      } catch (e) {
        lastError = e;
        if (attempt + 1 < attempts) {
          await Future<void>.delayed(
              Duration(milliseconds: 300 * (1 << attempt)));
        }
      }
    }
    throw lastError ?? const HttpException('Request failed');
  }

  static Future<File> _catalogCacheFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/camanime_catalog_v1.json');
  }

  static Future<Map<String, dynamic>> catalogHome() async {
    final b = base();
    try {
      final response = await _get(Uri.parse('$b/api/v1/catalog/home'));
      final body = json.decode(response.body) as Map<String, dynamic>;
      final catalog = (body['catalog'] as Map?)?.cast<String, dynamic>() ??
          <String, dynamic>{};
      final cache = await _catalogCacheFile();
      await cache.parent.create(recursive: true);
      await cache.writeAsString(json.encode(catalog), flush: true);
      return {'catalog': catalog, 'offline': false};
    } catch (_) {
      final cache = await _catalogCacheFile();
      if (await cache.exists()) {
        try {
          final catalog = (json.decode(await cache.readAsString()) as Map)
              .cast<String, dynamic>();
          return {'catalog': catalog, 'offline': true};
        } catch (_) {
          await cache.delete();
        }
      }
      rethrow;
    }
  }

  static Future<List> search(String q) async {
    final response = await _get(Uri.parse(
        '${base()}/api/v1/search?q=${Uri.encodeQueryComponent(q)}&limit=36'));
    return ((json.decode(response.body) as Map)['results'] as List?) ?? [];
  }

  static Future<Map<String, dynamic>> animeInfo(String animeId) async {
    final response = await _get(
        Uri.parse('${base()}/api/v1/anime/${Uri.encodeComponent(animeId)}'));
    return ((json.decode(response.body) as Map)['anime'] as Map?)
            ?.cast<String, dynamic>() ??
        {};
  }

  /// Same streaming servers the website uses for this episode.
  static Future<Map<String, dynamic>> episodeSources(
      String animeId, int ep, String audio) async {
    final response = await _get(Uri.parse(
        '${base()}/api/episode-sources/${Uri.encodeComponent(animeId)}/$ep?audio=$audio'));
    return json.decode(response.body) as Map<String, dynamic>;
  }

  /// Official YouTube trailer id for a title, resolved by the website (AniList
  /// first, then a live search). Returns null when none is found.
  static Future<String?> trailer(String animeId, String title) async {
    final response = await _get(
        Uri.parse('${base()}/api/trailer'
            '?anime_id=${Uri.encodeComponent(animeId)}'
            '&title=${Uri.encodeQueryComponent(title)}'),
        timeout: const Duration(seconds: 25));
    final data = json.decode(response.body) as Map<String, dynamic>;
    final id = (data['youtube_id'] ?? '').toString().trim();
    return RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id) ? id : null;
  }

  /// One page of the live catalogue. Powers Explore's endless browse and the
  /// personalised rows: any genre, any sort, and older titles via [yearBefore].
  static Future<List> browse({
    String genre = '',
    String sort = 'popular',
    int page = 1,
    int limit = 24,
    int? yearBefore,
    String format = '',
  }) async {
    final params = <String, String>{
      'sort': sort,
      'page': '$page',
      'limit': '$limit',
      if (genre.isNotEmpty) 'genre': genre,
      if (format.isNotEmpty) 'format': format,
      if (yearBefore != null) 'year_before': '$yearBefore',
    };
    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final response = await _get(Uri.parse('${base()}/api/v1/anime?$query'));
    return ((json.decode(response.body) as Map)['results'] as List?) ?? [];
  }

  static Future<List> genres() async {
    final response = await _get(Uri.parse('${base()}/api/v1/genres'));
    return ((json.decode(response.body) as Map)['genres'] as List?) ?? [];
  }

  static Future<List> genreAnime(String slug) async {
    final response = await _get(Uri.parse(
        '${base()}/api/v1/genres/${Uri.encodeComponent(slug)}/anime?limit=36'));
    return ((json.decode(response.body) as Map)['results'] as List?) ?? [];
  }

  static Future<List> comments(String animeId) async {
    final response = await _get(Uri.parse(
        '${base()}/api/community/comments?anime_id=${Uri.encodeComponent(animeId)}'));
    return ((json.decode(response.body) as Map)['comments'] as List?) ?? [];
  }

  static Future<void> postComment(String animeId, String text) async {
    final fd = {'anime_id': animeId, 'text': text, 'name': await guestName()};
    final r = await http
        .post(Uri.parse('${base()}/api/community/comment'), body: fd)
        .timeout(const Duration(seconds: 15));
    final d = json.decode(r.body) as Map<String, dynamic>;
    if (d['status'] != 'success') throw Exception(d['error'] ?? 'Post failed');
  }

  static Future<void> rate(String animeId, int score) async {
    final fd = {
      'anime_id': animeId,
      'score': '$score',
      'name': await guestName()
    };
    final r = await http
        .post(Uri.parse('${base()}/api/community/rate'), body: fd)
        .timeout(const Duration(seconds: 15));
    final d = json.decode(r.body) as Map<String, dynamic>;
    if (d['status'] != 'success') throw Exception(d['error'] ?? 'Rate failed');
  }

  static Future<Map<String, dynamic>> announcements() async {
    final r = await http
        .get(Uri.parse('${base()}/api/announcements'))
        .timeout(const Duration(seconds: 12));
    return json.decode(r.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> version() async {
    final r = await http
        .get(Uri.parse('${base()}/api/version'))
        .timeout(const Duration(seconds: 12));
    return json.decode(r.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> signIn(String email, String password,
      {bool register = false, String name = ''}) async {
    final b = base();
    final path = register ? 'register' : 'login';
    final r = await http.post(Uri.parse('$b/api/auth/$path'),
        headers: {'Content-Type': 'application/json'},
        body:
            json.encode({'email': email, 'password': password, 'name': name}));
    final d = json.decode(r.body) as Map<String, dynamic>;
    if (d['status'] != 'success') {
      throw Exception(d['error'] ?? 'Sign-in failed');
    }
    final p = await SharedPreferences.getInstance();
    await p.setString('api_token', d['token']);
    await p.setString('user_email', (d['user'] as Map)['email']);
    await p.setString('username', (d['user'] as Map)['name']);
    return d['user'] as Map<String, dynamic>;
  }

  static Future<void> signOut() async {
    try {
      await http.post(Uri.parse('${base()}/api/auth/logout'),
          headers: await headers());
    } catch (_) {}
    final p = await SharedPreferences.getInstance();
    await p.remove('api_token');
    await p.remove('user_email');
  }

  /// Signed-in user profile: also tells us the role (admin vs user).
  static Future<Map<String, dynamic>> me() async {
    final r = await _get(Uri.parse('${base()}/api/auth/me'),
        timeout: const Duration(seconds: 12));
    return json.decode(r.body) as Map<String, dynamic>;
  }

  /// Direct MP4 download from the website's own download manager.
  /// Saves into the private in-app library; export via Library > Save.
  static Future<MediaDownloadResult> downloadEpisodeFile(
      String websiteUrl, String filename,
      {void Function(int received, int total)? onProgress,
      bool Function()? isCancelled}) async {
    final uri = Uri.parse(abs(websiteUrl));
    if (uri.scheme != 'https' || !uri.hasAuthority) {
      throw const HttpException('Downloads require a secure HTTPS source.');
    }
    final req = http.Request('GET', uri);
    req.headers.addAll(await headers());
    final client = http.Client();
    final dir = await getApplicationSupportDirectory();
    final library = Directory('${dir.path}/camanime_library');
    await library.create(recursive: true);
    final safe = safeMediaFilename(filename);
    final id = sha256.convert(utf8.encode('${uri.path}\u0000$safe')).toString();
    final finalFile = File('${library.path}/$id-$safe');
    final tempFile = File('${finalFile.path}.part');
    try {
      final response =
          await client.send(req).timeout(const Duration(seconds: 40));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.drain<void>();
        throw HttpException('CamAnime download failed (${response.statusCode})',
            uri: uri);
      }
      final contentType = response.headers['content-type'] ?? '';
      if (!isPlayableVideoType(contentType)) {
        await response.stream.drain<void>();
        throw HttpException(
            'Source is not a downloadable video ($contentType). HLS playlists and embed pages cannot be saved as MP4.',
            uri: uri);
      }
      final total = response.contentLength ?? 0;
      if (total == 0) {
        await response.stream.drain<void>();
        throw HttpException('The source returned an empty video file.',
            uri: uri);
      }
      if (await finalFile.exists()) {
        await response.stream.drain<void>();
        if (await finalFile.length() > 0) {
          return MediaDownloadResult(
              file: finalFile, downloadedBytes: await finalFile.length());
        }
        await finalFile.delete();
      }
      if (await tempFile.exists()) await tempFile.delete();
      final sink = tempFile.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.stream) {
          if (isCancelled?.call() == true) throw const MediaDownloadCancelled();
          received += chunk.length;
          sink.add(chunk);
          onProgress?.call(received, total);
        }
        await sink.flush();
        await sink.close();
      } catch (_) {
        await sink.close();
        rethrow;
      }
      if (received == 0 || (total > 0 && received != total)) {
        throw HttpException(
            'Incomplete video transfer ($received/${total > 0 ? total : 'unknown'} bytes).');
      }
      final handle = await tempFile.open();
      final header = await handle.read(16);
      await handle.close();
      final validHeader = header.length >= 8 &&
          (String.fromCharCodes(header.sublist(4, 8)) == 'ftyp' ||
              (header[0] == 0x1A &&
                  header[1] == 0x45 &&
                  header[2] == 0xDF &&
                  header[3] == 0xA3) ||
              (header[0] == 0x00 && header[1] == 0x00 && header[2] == 0x00));
      if (!validHeader) {
        throw HttpException(
            'Downloaded data does not look like a supported video file.');
      }
      await tempFile.rename(finalFile.path);
      return MediaDownloadResult(file: finalFile, downloadedBytes: received);
    } catch (_) {
      if (await tempFile.exists()) await tempFile.delete();
      rethrow;
    } finally {
      client.close();
    }
  }
}

class MediaDownloadResult {
  final File file;
  final int downloadedBytes;
  const MediaDownloadResult(
      {required this.file, required this.downloadedBytes});
}

class MediaLibraryItem {
  final String id;
  final String title;
  final int? animeId;
  final int? episode;
  final String audio;
  final File file;
  final int sizeBytes;
  final DateTime completedAt;
  const MediaLibraryItem({
    required this.id,
    required this.title,
    required this.animeId,
    required this.episode,
    required this.audio,
    required this.file,
    required this.sizeBytes,
    required this.completedAt,
  });
}

class MediaLibrary {
  static Future<Directory> directory() async {
    final dir = await getApplicationSupportDirectory();
    final library = Directory('${dir.path}/camanime_library');
    await library.create(recursive: true);
    return library;
  }

  static Future<File> _manifest(Directory library) async =>
      File('${library.path}/library.json');

  static Future<void> record({
    required File file,
    required String title,
    required int animeId,
    required int episode,
    required String audio,
    required int sizeBytes,
  }) async {
    final library = await directory();
    final manifest = await _manifest(library);
    List<Map<String, dynamic>> rows = [];
    if (await manifest.exists()) {
      try {
        rows = (json.decode(await manifest.readAsString()) as List)
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
      } catch (_) {
        rows = [];
      }
    }
    final id = sha256.convert(utf8.encode('${animeId}_$episode')).toString();
    rows.removeWhere(
        (e) => e['id'] == id || e['file'] == file.uri.pathSegments.last);
    rows.add({
      'id': id,
      'title': title,
      'anime_id': animeId,
      'episode': episode,
      'audio': audio,
      'file': file.uri.pathSegments.last,
      'size_bytes': sizeBytes,
      'completed_at': DateTime.now().toUtc().toIso8601String(),
      'format': 'mp4',
      'status': 'completed',
    });
    final temp = File('${manifest.path}.tmp');
    await temp.writeAsString(json.encode(rows), flush: true);
    if (await manifest.exists()) await manifest.delete();
    await temp.rename(manifest.path);
  }

  static Future<List<MediaLibraryItem>> list() async {
    final library = await directory();
    final manifest = await _manifest(library);
    List<Map<String, dynamic>> rows = [];
    if (await manifest.exists()) {
      try {
        rows = (json.decode(await manifest.readAsString()) as List)
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
      } catch (_) {
        rows = [];
      }
    }
    final byFile = {for (final row in rows) row['file']: row};
    final items = <MediaLibraryItem>[];
    await for (final entity in library.list()) {
      if (entity is! File ||
          entity.path.endsWith('.part') ||
          entity.path.endsWith('.tmp') ||
          entity.path.endsWith('library.json')) {
        continue;
      }
      final name = entity.uri.pathSegments.last;
      final row = byFile[name];
      try {
        final size = await entity.length();
        final stat = await entity.stat();
        if (size < 12 || !_isMp4File(entity)) continue;
        items.add(MediaLibraryItem(
          id: (row?['id'] ?? name).toString(),
          title: (row?['title'] ?? name).toString(),
          animeId: row?['anime_id'] as int?,
          episode: row?['episode'] as int?,
          audio: (row?['audio'] ?? 'sub').toString(),
          file: entity,
          sizeBytes: size,
          completedAt:
              DateTime.tryParse((row?['completed_at'] ?? '').toString()) ??
                  stat.modified,
        ));
      } catch (_) {
        // Files disappearing during a refresh are omitted and can be retried.
      }
    }
    items.sort((a, b) => b.completedAt.compareTo(a.completedAt));
    return items;
  }

  static Future<void> delete(MediaLibraryItem item) async {
    if (await item.file.exists()) await item.file.delete();
    final library = await directory();
    final manifest = await _manifest(library);
    if (!await manifest.exists()) return;
    try {
      final rows = (json.decode(await manifest.readAsString()) as List)
          .whereType<Map>()
          .where((e) =>
              e['id'] != item.id &&
              e['file'] != item.file.uri.pathSegments.last)
          .toList();
      final temp = File('${manifest.path}.tmp');
      await temp.writeAsString(json.encode(rows), flush: true);
      await manifest.delete();
      await temp.rename(manifest.path);
    } catch (_) {
      // File is deleted; a damaged index is reconstructed by the scanner.
    }
  }

  static bool _isMp4File(File file) {
    final ext = file.path.toLowerCase();
    return ext.endsWith('.mp4') || ext.endsWith('.m4v');
  }
}

class MediaDownloadCancelled implements Exception {
  const MediaDownloadCancelled();
  @override
  String toString() => 'Download cancelled';
}

// ── Shared widgets ─────────────────────────────────────
class PosterCard extends StatelessWidget {
  final Map item;
  final double width;
  const PosterCard({super.key, required this.item, this.width = 128});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => DetailScreen(
                  animeId: item['id'].toString(),
                  title: (item['title'] ?? '').toString()))),
      child: SizedBox(
        width: width,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: AspectRatio(
              aspectRatio: 2 / 2.85,
              child: CachedPosterImage(url: (item['image'] ?? '').toString()),
            ),
          ),
          const SizedBox(height: 6),
          Text((item['title'] ?? 'Unknown').toString(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }
}

class CachedPosterImage extends StatefulWidget {
  final String url;
  const CachedPosterImage({super.key, required this.url});
  @override
  State<CachedPosterImage> createState() => _CachedPosterImageState();
}

class _CachedPosterImageState extends State<CachedPosterImage> {
  File? cachedFile;
  bool loading = true;

  String _fileName(String value) {
    var hash = 2166136261;
    for (final unit in value.codeUnits) {
      hash = ((hash ^ unit) * 16777619) & 0xffffffff;
    }
    return 'poster_${hash.toRadixString(16)}.img';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant CachedPosterImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _load();
    }
  }

  Future<void> _load() async {
    final url = widget.url.trim();
    if (url.isEmpty) {
      if (mounted) {
        setState(() {
          cachedFile = null;
          loading = false;
        });
      }
      return;
    }
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/camanime_posters/${_fileName(url)}');
    if (await file.exists() && await file.length() > 1024 && mounted) {
      setState(() {
        cachedFile = file;
        loading = false;
      });
    } else if (mounted) {
      setState(() {
        cachedFile = null;
        loading = true;
      });
    }
    try {
      final response =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200 && response.bodyBytes.length > 1024) {
        await file.parent.create(recursive: true);
        final temp = File('${file.path}.tmp');
        await temp.writeAsBytes(response.bodyBytes, flush: true);
        if (await file.exists()) await file.delete();
        await temp.rename(file.path);
        if (mounted && widget.url.trim() == url) {
          setState(() {
            cachedFile = file;
            loading = false;
          });
        }
      }
    } catch (_) {
      // Keep an existing poster visible offline; otherwise show the fallback.
    }
    if (mounted && widget.url.trim() == url) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (cachedFile != null) {
      return Image.file(cachedFile!,
          fit: BoxFit.cover, errorBuilder: (_, __, ___) => _fallback());
    }
    if (loading) {
      return Container(
          color: card2,
          alignment: Alignment.center,
          child: const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2, color: amber)));
    }
    return _fallback();
  }

  Widget _fallback() => Container(
      color: card2,
      alignment: Alignment.center,
      child: const Icon(Icons.movie_outlined, color: muted, size: 30));
}

// ── Tutorial ───────────────────────────────────────────
class TutorialOverlay extends StatefulWidget {
  final VoidCallback onDone;
  const TutorialOverlay({super.key, required this.onDone});
  @override
  State<TutorialOverlay> createState() => _TutorialOverlayState();
}

class _TutorialOverlayState extends State<TutorialOverlay> {
  int i = 0;
  static const steps = [
    [
      'Discover anime',
      'Browse the catalogue shared with the CamAnime website. No account needed to explore.'
    ],
    [
      'Watch in the app',
      'Episodes stream with the same servers as the website — SUB & DUB, straight in the app.'
    ],
    [
      'Downloads from CamAnime',
      'Pick single or multiple episodes and save MP4s into My Library. No sign-in needed.'
    ],
    [
      'You, your way',
      'Set a profile pic, switch themes, and comment under every anime as a guest.'
    ],
  ];
  @override
  Widget build(BuildContext context) => Container(
        color: Colors.black.withValues(alpha: 0.9),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  minHeight: MediaQuery.of(context).size.height - 56),
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                          gradient: const LinearGradient(colors: [amber, pink]),
                          borderRadius: BorderRadius.circular(22)),
                      child: const Icon(Icons.play_circle_fill,
                          color: Colors.black, size: 44),
                    ),
                    const SizedBox(height: 18),
                    Text('Step ${i + 1} of ${steps.length}',
                        style: const TextStyle(color: muted, fontSize: 12)),
                    const SizedBox(height: 6),
                    Text(steps[i][0],
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 24, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 8),
                    Text(steps[i][1],
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: muted, fontSize: 15)),
                    const SizedBox(height: 20),
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      for (var k = 0; k < steps.length; k++)
                        Container(
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            width: i == k ? 26 : 8,
                            height: 8,
                            decoration: BoxDecoration(
                                color: i == k ? amber : muted,
                                borderRadius: BorderRadius.circular(99))),
                    ]),
                    const SizedBox(height: 20),
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      if (i > 0)
                        OutlinedButton(
                          onPressed: () => setState(() => i--),
                          child: const Text('Back'),
                        ),
                      if (i > 0) const SizedBox(width: 10),
                      FilledButton(
                        style: FilledButton.styleFrom(
                            backgroundColor: amber,
                            foregroundColor: Colors.black,
                            minimumSize: const Size(140, 48)),
                        onPressed: () => i < steps.length - 1
                            ? setState(() => i++)
                            : widget.onDone(),
                        child: Text(
                            i < steps.length - 1 ? 'Next' : 'Start watching'),
                      ),
                    ]),
                    TextButton(
                      onPressed: widget.onDone,
                      child: const Text('Skip tour'),
                    ),
                  ]),
            ),
          ),
        ),
      );
}

// ── Home (slideshow + rails) ───────────────────────────
class HomeTab extends StatefulWidget {
  final VoidCallback onUpdate;
  const HomeTab({super.key, required this.onUpdate});
  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> with WidgetsBindingObserver {
  List trending = [],
      popular = [],
      topRated = [],
      fresh = [],
      movies = [],
      series = [],
      classics = [],
      ann = [];

  /// Shown when the deployed API predates the classics row. These are real
  /// AniList ids, so tapping one resolves the normal streaming servers — the
  /// classics are not a special case in the player or the downloader.
  static const List<Map<String, dynamic>> _classicFallback = [
    {'id': 1, 'title': 'Cowboy Bebop', 'format': 'TV', 'year': 1998},
    {'id': 16429, 'title': 'Death Note', 'format': 'TV', 'year': 2006},
    {
      'id': 5114,
      'title': 'Fullmetal Alchemist: Brotherhood',
      'format': 'TV',
      'year': 2009
    },
    {'id': 321, 'title': 'Samurai Champloo', 'format': 'TV', 'year': 2004},
    {'id': 199, 'title': 'Spirited Away', 'format': 'MOVIE', 'year': 2001},
    {'id': 20, 'title': 'Naruto Shippuden', 'format': 'TV', 'year': 2007},
    {'id': 16498, 'title': 'Attack on Titan', 'format': 'TV', 'year': 2013},
    {'id': 5680, 'title': 'K-On!', 'format': 'TV', 'year': 2009},
    {'id': 11719, 'title': 'Sword Art Online', 'format': 'TV', 'year': 2012},
  ];

  Map? featured;

  /// Episodes this device started but did not finish, newest first.
  List<Map<String, dynamic>> resume = [];

  /// Rows are shuffled once per app open, so the shelf feels fresh each launch
  /// without losing their meaning when the user pulls to refresh.
  bool _shuffled = false;
  bool loading = true;
  bool offline = false;
  String? err;
  DateTime? _lastRefresh;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        (_lastRefresh == null ||
            DateTime.now().difference(_lastRefresh!) >
                const Duration(minutes: 1))) {
      _load();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Reads the saved watch spots so Home can offer a one-tap continue.
  Future<void> _loadResume() async {
    final ids = await WatchProgress.recentAnimeIds(limit: 10);
    final rows = <Map<String, dynamic>>[];
    for (final id in ids) {
      final latest = await WatchProgress.latest(id);
      if (latest == null) continue;
      rows.add({
        'id': id,
        'title': (latest['title'] ?? 'Continue watching').toString(),
        'image': (latest['image'] ?? '').toString(),
        'episode': int.tryParse('${latest['ep']}') ?? 1,
        'posMs': int.tryParse('${latest['posMs']}') ?? 0,
        'durMs': int.tryParse('${latest['durMs']}') ?? 0,
      });
    }
    if (!mounted) return;
    setState(() => resume = rows);
  }

  Future<void> _load() async {
    _lastRefresh = DateTime.now();
    unawaited(_loadResume());
    try {
      final result = await Api.catalogHome();
      final data = (result['catalog'] as Map?)?.cast<String, dynamic>() ??
          <String, dynamic>{};
      List list(String key) => (data[key] as List?) ?? [];
      Map? hero = data['featured'] is Map
          ? (data['featured'] as Map).cast<String, dynamic>()
          : null;
      try {
        final announcements = await Api.announcements();
        ann = (announcements['announcements'] as List?) ?? [];
        unawaited(AppNotifications.announcements(ann));
      } catch (_) {
        // Catalogue availability does not depend on the announcements service.
      }
      if (!mounted) {
        return;
      }
      setState(() {
        trending = list('trending');
        popular = list('popular');
        topRated = list('top_rated');
        fresh = list('recently_added');
        movies = list('movies');
        series = list('series');
        classics = list('classics');
        if (classics.isEmpty) classics = List.of(_classicFallback);
        featured = hero;
        if (!_shuffled) {
          _shuffled = true;
          final rng = Random();
          for (final row in [
            trending,
            popular,
            topRated,
            fresh,
            movies,
            series,
            classics
          ]) {
            row.shuffle(rng);
          }
        }
        offline = result['offline'] == true;
        err = trending.isEmpty && popular.isEmpty && topRated.isEmpty
            ? 'The catalogue is empty right now. Pull to retry.'
            : null;
        loading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        err =
            'CamAnime is offline and no saved catalogue is available yet. Pull to retry.';
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        onRefresh: () async {
          setState(() => loading = true);
          await _load();
        },
        child: Builder(builder: (ctx) {
          final kids = <Widget>[_header()];
          if (offline) {
            kids.add(const Padding(
                padding: EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Row(children: [
                  Icon(Icons.cloud_off, size: 16, color: muted),
                  SizedBox(width: 7),
                  Text('Offline · saved catalogue',
                      style: TextStyle(color: muted, fontSize: 12))
                ])));
          }
          if (loading && trending.isEmpty && popular.isEmpty) {
            kids.add(const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator(color: amber))));
          } else if (err != null && trending.isEmpty && popular.isEmpty) {
            kids.add(Padding(
                padding: const EdgeInsets.all(24),
                child: Column(children: [
                  const Icon(Icons.wifi_off, size: 48, color: muted),
                  const SizedBox(height: 8),
                  Text(err!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: muted)),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                        backgroundColor: amber, foregroundColor: Colors.black),
                    onPressed: _load,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Try again'),
                  ),
                ])));
          } else {
            kids.addAll(_homeContent());
          }
          return RefreshIndicator(
              color: amber,
              backgroundColor: card,
              onRefresh: _load,
              child: ListView(
                  padding: const EdgeInsets.only(bottom: 110), children: kids));
        }),
      );

  Widget _header() => Container(
        padding: const EdgeInsets.fromLTRB(20, 52, 20, 18),
        decoration: const BoxDecoration(
            gradient: LinearGradient(
                colors: [Color(0xFF061225), bg],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight)),
        child: Row(children: [
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Image.asset('assets/brand/camanime-logo.png',
                    key: const ValueKey('camanime-brand-logo'),
                    width: 225,
                    height: 52,
                    fit: BoxFit.contain,
                    alignment: Alignment.centerLeft,
                    semanticLabel: 'CamAnime — Watch, discover, enjoy'),
                const SizedBox(height: 4),
                const Text('ANIME DISCOVERY',
                    style: TextStyle(
                        color: muted,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.6)),
              ])),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
                color: mint.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(99),
                border: Border.all(color: mint.withValues(alpha: 0.4))),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                  width: 8,
                  height: 8,
                  decoration:
                      const BoxDecoration(color: mint, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              const Text('Connected',
                  style: TextStyle(
                      color: mint, fontSize: 11, fontWeight: FontWeight.w800)),
            ]),
          ),
        ]),
      );

  List<Widget> _homeContent() {
    final out = <Widget>[];
    if (ann.isNotEmpty) {
      out.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: Card(
            child: ListTile(
          leading: const Icon(Icons.campaign, color: amber),
          title: Text((ann.first['title'] ?? '').toString(),
              style: const TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Text((ann.first['body'] ?? '').toString(),
              maxLines: 2, overflow: TextOverflow.ellipsis),
        )),
      ));
    }
    final slides = trending.isNotEmpty ? trending.take(6).toList() : [];
    if (slides.isNotEmpty) out.add(_slideshow(slides));
    if (resume.isNotEmpty) out.add(_resumeRail());
    if (featured != null) out.add(_featuredCard(featured!));
    out.add(_rail('Trending Anime', trending));
    out.add(_rail('Popular this season', popular));
    out.add(_rail('Top Rated', topRated));
    out.add(_rail('Recently Added', fresh));
    out.add(_rail('Popular Movies', movies));
    out.add(_rail('Popular Series', series));
    out.add(_rail('Anime Classics', classics));
    out.add(Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: _openBrowse,
          icon: const Icon(Icons.grid_view_rounded, size: 17),
          label: const Text('View more'),
        ),
      ),
    ));

    if (offline) {
      out.add(const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text('Reconnect to refresh artwork and catalogue data.',
              style: TextStyle(color: muted, fontSize: 12))));
    }
    out.add(const Padding(
        padding: EdgeInsets.all(16),
        child: Text(appCredit,
            textAlign: TextAlign.center,
            style: TextStyle(color: muted, fontSize: 12))));
    return out;
  }

  /// Opens the full catalogue browser — the same surface the Explore tab uses.
  void _openBrowse() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const BrowseScreen()));
  }

  Widget _slideshow(List slides) => _Slideshow(items: slides);

  Widget _featuredCard(Map item) {
    final image = (item['banner'] ?? item['image'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: GestureDetector(
        onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => DetailScreen(
                    animeId: item['id'].toString(),
                    title: (item['title'] ?? 'Anime').toString()))),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: SizedBox(
            height: 245,
            child: Stack(fit: StackFit.expand, children: [
              CachedPosterImage(url: image),
              const DecoratedBox(
                  decoration: BoxDecoration(
                      gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x11000000), Color(0xEE07080D)],
                          stops: [0.12, 1.0]))),
              Positioned(
                  left: 16,
                  right: 16,
                  bottom: 16,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text((item['title'] ?? 'Featured Anime').toString(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 23, fontWeight: FontWeight.w900)),
                        const SizedBox(height: 5),
                        Text(
                            ((item['genres'] as List?) ?? [])
                                .take(3)
                                .join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12)),
                        const SizedBox(height: 8),
                        Row(children: [
                          const Icon(Icons.play_circle_fill,
                              color: amber, size: 20),
                          const SizedBox(width: 6),
                          Text(
                              '${item['format'] ?? 'ANIME'}  ·  ${item['year'] ?? ''}',
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.white70,
                                  fontWeight: FontWeight.w600)),
                        ]),
                      ])),
            ]),
          ),
        ),
      ),
    );
  }

  /// "Continue watching": the exact episode and second this device stopped at.
  Widget _resumeRail() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(children: [
              const Text('Continue watching',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              const Spacer(),
              TextButton(
                onPressed: () async {
                  await WatchProgress.clearAll();
                  if (mounted) setState(() => resume = []);
                },
                child: const Text('Clear'),
              ),
            ]),
          ),
          SizedBox(
            height: 214,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: resume.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final row = resume[i];
                final pos = row['posMs'] as int;
                final dur = row['durMs'] as int;
                final progress = dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0.0;
                return GestureDetector(
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => DetailScreen(
                              animeId: row['id'].toString(),
                              title: row['title'].toString()))),
                  child: SizedBox(
                    width: 128,
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: AspectRatio(
                              aspectRatio: 2 / 2.7,
                              child: Stack(fit: StackFit.expand, children: [
                                CachedPosterImage(url: row['image'].toString()),
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 0,
                                  child: LinearProgressIndicator(
                                    value: progress,
                                    minHeight: 3,
                                    backgroundColor: Colors.black54,
                                    valueColor:
                                        const AlwaysStoppedAnimation<Color>(
                                            amber),
                                  ),
                                ),
                              ]),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(row['title'].toString(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 12, fontWeight: FontWeight.w700)),
                          Text(
                            'Ep ${row['episode']} · ${_clock(pos)} in',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                const TextStyle(color: muted, fontSize: 10.5),
                          ),
                        ]),
                  ),
                );
              },
            ),
          ),
        ],
      );

  String _clock(int ms) {
    final total = (ms / 1000).round().clamp(0, 1 << 30);
    final m = total ~/ 60;
    final ss = (total % 60).toString().padLeft(2, '0');
    return '$m:$ss';
  }

  Widget _rail(String title, List items) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(title,
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w800))),
        SizedBox(
          height: 236,
          child: items.isEmpty
              ? const Center(
                  child: Text('Nothing here yet — pull to refresh.',
                      style: TextStyle(color: muted)))
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (_, i) => PosterCard(item: items[i] as Map),
                ),
        ),
      ]);
}

/// Auto-rotating anime slideshow (16:9 stage, dots + tap to open).
class _Slideshow extends StatefulWidget {
  final List items;
  const _Slideshow({required this.items});
  @override
  State<_Slideshow> createState() => _SlideshowState();
}

class _SlideshowState extends State<_Slideshow> {
  final _ctrl = PageController(viewportFraction: 0.92);
  Timer? _timer;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || widget.items.isEmpty) return;
      _page = (_page + 1) % widget.items.length;
      _ctrl.animateToPage(_page,
          duration: const Duration(milliseconds: 450), curve: Curves.easeOut);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      SizedBox(
        height: 210,
        child: PageView.builder(
          controller: _ctrl,
          onPageChanged: (i) => setState(() => _page = i),
          itemCount: widget.items.length,
          itemBuilder: (_, i) {
            final item = widget.items[i] as Map;
            final img = (item['banner'] ?? item['image'] ?? '').toString();
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: GestureDetector(
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => DetailScreen(
                            animeId: item['id'].toString(),
                            title: (item['title'] ?? 'Anime').toString()))),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Stack(fit: StackFit.expand, children: [
                    CachedPosterImage(url: img),
                    const DecoratedBox(
                        decoration: BoxDecoration(
                            gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                          Color(0x08000000),
                          Color(0xDD07080D)
                        ]))),
                    Positioned(
                        left: 14,
                        right: 14,
                        bottom: 12,
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                      color: amber,
                                      borderRadius: BorderRadius.circular(6)),
                                  child: Text('TRENDING #${i + 1}',
                                      style: const TextStyle(
                                          color: Colors.black,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w900))),
                              const SizedBox(height: 4),
                              Text((item['title'] ?? '').toString(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w900)),
                              Text('Tap to watch · stream & download free',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.white
                                          .withValues(alpha: 0.75))),
                            ])),
                  ]),
                ),
              ),
            );
          },
        ),
      ),
      const SizedBox(height: 8),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        for (var k = 0; k < widget.items.length; k++)
          Container(
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: _page == k ? 22 : 7,
              height: 7,
              decoration: BoxDecoration(
                  color: _page == k ? amber : muted,
                  borderRadius: BorderRadius.circular(99))),
      ]),
    ]);
  }
}

// ── Explore (real rails + genres) ───────────────────────
class ExploreTab extends StatefulWidget {
  const ExploreTab({super.key});
  @override
  State<ExploreTab> createState() => _ExploreTabState();
}

class _ExploreTabState extends State<ExploreTab> {
  List trending = [], popular = [], topRated = [], movies = [];
  List genres = [];
  String? genreSlug;
  List genreResults = [];
  bool loading = true;
  bool genreBusy = false;

  /// Personalised rows: built from the genres of what this person actually
  /// watches and downloads, so Explore is not the same list for everybody.
  List forYou = [];
  List tasteGenres = [];
  bool tasteLoading = true;

  /// Endless browse: any page of the live catalogue, old titles included.
  static const _sorts = {
    'popular': 'Most popular',
    'trending': 'Trending',
    'top_rated': 'Top rated',
    'newest': 'Newest',
  };
  String browseSort = 'popular';
  bool browseOlder = false;
  List browseRows = [];
  int browsePage = 1;
  bool browseBusy = false;
  bool browseDone = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadTaste();
    _loadBrowse(reset: true);
  }

  Future<void> _load() async {
    try {
      final result = await Api.catalogHome();
      final data = (result['catalog'] as Map?)?.cast<String, dynamic>() ??
          <String, dynamic>{};
      List list(String key) => (data[key] as List?) ?? [];
      List g = [];
      try {
        g = await Api.genres();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        trending = list('trending');
        popular = list('popular');
        topRated = list('top_rated');
        movies = list('movies');
        genres = g;
        loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  /// Reads what this device has watched and downloaded, learns the genres, and
  /// asks the catalogue for more titles the same person is likely to start.
  Future<void> _loadTaste() async {
    try {
      final watched = await WatchProgress.recentAnimeIds(limit: 8);
      final downloaded = DownloadManager.instance.tasks
          .map((t) => t.animeId.toString())
          .where((id) => id != '0')
          .toList();
      final ids = <String>{...watched, ...downloaded}.take(8).toList();
      final counts = <String, int>{};
      final names = <String, String>{};
      for (final id in ids) {
        try {
          final info = await Api.animeInfo(id);
          final title = (info['title'] ?? '').toString();
          if (title.isNotEmpty) names[id] = title;
          for (final g in (info['genres'] as List?) ?? const []) {
            final name = (g['name'] ?? g).toString();
            if (name.isEmpty) continue;
            counts[name] = (counts[name] ?? 0) + 1;
          }
        } catch (_) {}
      }
      final ranked = counts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final top = ranked.take(3).map((e) => e.key).toList();
      final picks = <Map>[];
      final seen = <String>{...ids};
      for (final genre in top) {
        for (final page in const [1, 2]) {
          final rows = await Api.browse(genre: genre, page: page, limit: 24);
          for (final raw in rows) {
            if (raw is! Map) continue;
            final id = (raw['id'] ?? '').toString();
            if (id.isEmpty || !seen.add(id)) continue;
            picks.add(raw);
            if (picks.length >= 24) break;
          }
          if (picks.length >= 24) break;
        }
        if (picks.length >= 24) break;
      }
      if (!mounted) return;
      setState(() {
        forYou = picks;
        tasteGenres = top;
        tasteLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => tasteLoading = false);
    }
  }

  Future<void> _loadBrowse({required bool reset}) async {
    if (browseBusy) return;
    if (!reset && browseDone) return;
    setState(() => browseBusy = true);
    final page = reset ? 1 : browsePage;
    try {
      final rows = await Api.browse(
        sort: browseSort,
        page: page,
        limit: 30,
        yearBefore: browseOlder ? 2015 : null,
        genre: genreSlug ?? '',
      );
      if (!mounted) return;
      setState(() {
        if (reset) browseRows = [];
        final seen = browseRows
            .map((e) => (e as Map)['id']?.toString())
            .whereType<String>()
            .toSet();
        for (final raw in rows) {
          if (raw is! Map) continue;
          final id = (raw['id'] ?? '').toString();
          if (id.isEmpty || !seen.add(id)) continue;
          browseRows.add(raw);
        }
        browsePage = page + 1;
        browseDone = rows.length < 30;
        browseBusy = false;
      });
    } catch (_) {
      if (mounted) setState(() => browseBusy = false);
    }
  }

  Future<void> _pickGenre(String? slug) async {
    setState(() {
      genreSlug = slug;
      genreBusy = slug != null;
      if (slug == null) genreResults = [];
    });
    if (slug == null) return;
    try {
      final r = await Api.genreAnime(slug);
      if (!mounted) return;
      setState(() {
        genreResults = r;
        genreBusy = false;
      });
    } catch (_) {
      if (mounted) setState(() => genreBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final cols = w < 360 ? 2 : 3;
    return SafeArea(
      child: loading
          ? const Center(child: CircularProgressIndicator(color: amber))
          : RefreshIndicator(
              color: amber,
              backgroundColor: card,
              onRefresh: _load,
              child: ListView(
                  padding: const EdgeInsets.only(bottom: 110),
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                      child: Text('Explore',
                          style: TextStyle(
                              fontSize: 24, fontWeight: FontWeight.w900)),
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                          'Rails and genres from the live CamAnime catalogue.',
                          style: TextStyle(color: muted, fontSize: 12)),
                    ),
                    if (genres.isNotEmpty) ...[
                      SizedBox(
                        height: 44,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: genres.length + 1,
                          separatorBuilder: (_, __) => const SizedBox(width: 8),
                          itemBuilder: (_, i) {
                            if (i == 0) {
                              final on = genreSlug == null;
                              return ChoiceChip(
                                  label: const Text('All'),
                                  selected: on,
                                  onSelected: (_) => _pickGenre(null));
                            }
                            final g = genres[i - 1] as Map;
                            final slug = (g['slug'] ?? '').toString();
                            return ChoiceChip(
                                label: Text((g['name'] ?? slug).toString()),
                                selected: genreSlug == slug,
                                onSelected: (_) => _pickGenre(slug));
                          },
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],
                    if (genreBusy)
                      const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(
                              child: CircularProgressIndicator(color: amber)))
                    else if (genreSlug != null)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: genreResults.isEmpty
                            ? const Text('No titles in this genre yet.',
                                style: TextStyle(color: muted))
                            : GridView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: cols,
                                        childAspectRatio: 0.56,
                                        crossAxisSpacing: 10,
                                        mainAxisSpacing: 12),
                                itemCount: genreResults.length,
                                itemBuilder: (_, i) => PosterCard(
                                    item: genreResults[i] as Map,
                                    width: double.infinity),
                              ),
                      )
                    else ...[
                      if (tasteLoading)
                        const Padding(
                            padding: EdgeInsets.symmetric(vertical: 18),
                            child: Center(
                                child: SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: amber))))
                      else if (forYou.isNotEmpty) ...[
                        _sectionHead(
                            'Made for you',
                            tasteGenres.isEmpty
                                ? 'Based on your watch history and downloads'
                                : 'Because you watch & download ${tasteGenres.join(' · ')}'),
                        _posterGrid(forYou, cols),
                      ] else ...[
                        _sectionHead('Made for you',
                            'Watch or download a few episodes and this row starts matching your taste.'),
                      ],
                      _sectionHead('Trending now', 'What everyone is watching'),
                      _miniRail('Trending now', trending),
                      _sectionHead('Popular this season', 'Currently airing'),
                      _miniRail('Popular this season', popular),
                      _sectionHead(
                          'All-time top rated', 'The classics that hold up'),
                      _miniRail('Top rated', topRated),
                      _sectionHead('Movies', 'One sitting, one story'),
                      _miniRail('Movies', movies),
                      _sectionHead('Browse the whole catalogue',
                          'Thousands of titles, old and new — keep loading'),
                      _browseControls(),
                      _posterGrid(browseRows, cols),
                      if (browseBusy)
                        const Padding(
                            padding: EdgeInsets.all(20),
                            child: Center(
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: amber)))
                      else if (!browseDone)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                          child: OutlinedButton.icon(
                            onPressed: () => _loadBrowse(reset: false),
                            icon: const Icon(Icons.expand_more_rounded),
                            label: const Text('Load more anime'),
                          ),
                        ),
                    ],
                  ])),
    );
  }

  Widget _sectionHead(String title, String subtitle) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style:
                  const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(subtitle, style: const TextStyle(color: muted, fontSize: 11.5)),
        ]),
      );

  Widget _posterGrid(List rows, int cols) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              childAspectRatio: 0.56,
              crossAxisSpacing: 10,
              mainAxisSpacing: 12),
          itemCount: rows.length,
          itemBuilder: (_, i) =>
              PosterCard(item: rows[i] as Map, width: double.infinity),
        ),
      );

  Widget _browseControls() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 7, runSpacing: 7, children: [
            for (final entry in _sorts.entries)
              ChoiceChip(
                label: Text(entry.value),
                selected: browseSort == entry.key,
                onSelected: (_) {
                  setState(() {
                    browseSort = entry.key;
                    browseDone = false;
                  });
                  _loadBrowse(reset: true);
                },
              ),
            FilterChip(
              label: const Text('Older classics'),
              selected: browseOlder,
              onSelected: (v) {
                setState(() {
                  browseOlder = v;
                  browseDone = false;
                });
                _loadBrowse(reset: true);
              },
            ),
          ]),
        ]),
      );

  Widget _miniRail(String title, List items) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          height: 236,
          child: items.isEmpty
              ? const Center(
                  child: Text('Nothing here yet — pull to refresh.',
                      style: TextStyle(color: muted)))
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (_, i) => PosterCard(item: items[i] as Map),
                ),
        ),
      ]);
}

/// Pushed, full-catalogue browse surface. Shares the Explore tab's live
/// catalogue, genre picker and paging so "View more" never lands on a stub.
class BrowseScreen extends StatelessWidget {
  const BrowseScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Browse anime')),
        body: const ExploreTab(),
      );
}

// ── Detail: banner, seasons, episodes, downloads, forum ─
class DetailScreen extends StatefulWidget {
  final String animeId;
  final String title;
  const DetailScreen({super.key, required this.animeId, required this.title});
  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  Map info = {};
  bool loading = true;
  bool dataSaver = false;
  String audio = 'sub';

  /// Provider-published audio for this title, learned from a real episode
  /// bundle. Null means "not checked yet", so DUB stays selectable until the
  /// server has actually reported whether the provider lists it.
  bool? _dubAvailable;

  void _applyAudioAvailability(Map<String, dynamic> bundle) {
    final raw = bundle['audio_availability'];
    if (raw is! Map || raw['dub'] is! bool) return;
    final dub = raw['dub'] as bool;
    if (_dubAvailable == dub) return;
    if (!mounted) return;
    setState(() {
      _dubAvailable = dub;
      if (!dub && audio == 'dub') audio = 'sub';
    });
  }

  String _sourceAudio(Map<String, dynamic> bundle) =>
      bundle['audio_fallback'] == true ? 'sub' : audio;

  void _noteAudioFallback(Map<String, dynamic> bundle, int ep) {
    if (bundle['audio_fallback'] != true || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('No provider dub for episode $ep — playing SUB. '
          'CamAnime only offers audio the source actually publishes.'),
    ));
  }

  /// First provider embed for an episode, used when no direct MP4/HLS source
  /// exists (common for the newest season). The provider still plays it; the
  /// app must not pretend the episode is unavailable.
  String? _providerEmbed(Map<String, dynamic> bundle) {
    for (final raw in (bundle['servers'] as List?) ?? const []) {
      if (raw is! Map) continue;
      if ((raw['playback_mode'] ?? '').toString() != 'iframe') continue;
      final url = (raw['embed_url'] ?? raw['stream_url'] ?? '').toString();
      if (url.startsWith('http')) return url;
    }
    return null;
  }

  Future<void> _openProviderEmbed(String url) async {
    var opened = false;
    try {
      opened =
          await launchUrl(Uri.parse(url), mode: LaunchMode.inAppBrowserView);
    } catch (_) {}
    if (!opened) {
      try {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
  }

  final Set<int> selected = {};
  String dlStatus = '';

  /// Download quality the user picked from the detail screen (persisted in
  /// `download_quality`, the same key Settings edits).
  String _dlQuality = '720';
  List comments = [];
  bool commentsBusy = false;
  String commentError = '';
  final _commentCtrl = TextEditingController();
  int? myScore;
  bool _saved = false;
  Map<int, EpisodePreview> previews = {};
  Map<int, double> watch = {};
  int? resumeEp;
  String trailerId = '';
  bool trailerBusy = false;

  /// Real episode count from the website. Never fabricates a number: titles
  /// still airing report their aired count through `next_airing_episode`.
  int get totalEps {
    final n = int.tryParse((info['episode_count'] ?? '').toString()) ?? 0;
    if (n > 0) return n > 500 ? 500 : n;
    final next =
        int.tryParse((info['next_airing_episode'] ?? '').toString()) ?? 0;
    return next > 1 ? next - 1 : 0;
  }

  /// Real related seasons/series for this anime, straight from the catalogue.
  List get seasons => (info['seasons'] as List?) ?? [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final p = await SharedPreferences.getInstance();
    audio = (p.getString('app_audio') ?? 'sub') == 'dub' ? 'dub' : 'sub';
    dataSaver = p.getBool('app_data_saver') ?? false;
    await _load();
    await _loadViewingState();
    final saved = await Watchlist.contains(widget.animeId);
    if (mounted && saved != _saved) setState(() => _saved = saved);
    final qualityPref = await _downloadPref();
    if (mounted && qualityPref != _dlQuality) {
      setState(() => _dlQuality = qualityPref);
    }
    // Resolve the servers for the episode the user is most likely to start in
    // the background, so the first Play/Download tap responds instantly.
    if (!dataSaver) unawaited(_warmFirstEpisode());
    await _loadComments();
  }

  Future<void> _load() async {
    try {
      final d = await Api.animeInfo(widget.animeId);
      if (!mounted) return;
      setState(() {
        info = d;
        previews = EpisodePreview.fromMetadata(
            (d['streaming_metadata'] as List?) ?? const []);
        trailerId = (d['trailer_id'] ?? '').toString().trim();
        loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _loadViewingState() async {
    final rows = await WatchProgress.all();
    final map = <int, double>{};
    for (final row in rows) {
      if ('${row['anime_id']}' != widget.animeId) continue;
      final ep = int.tryParse('${row['ep']}') ?? 0;
      final pos = int.tryParse('${row['posMs']}') ?? 0;
      final dur = int.tryParse('${row['durMs']}') ?? 0;
      if (ep > 0 && dur > 0) map[ep] = (pos / dur).clamp(0.0, 1.0);
    }
    final latest = await WatchProgress.latest(widget.animeId);
    if (!mounted) return;
    setState(() {
      watch = map;
      resumeEp = int.tryParse('${latest?['ep']}');
    });
  }

  Future<void> _loadComments() async {
    setState(() {
      commentsBusy = true;
      commentError = '';
    });
    try {
      final c = await Api.comments(widget.animeId);
      if (!mounted) return;
      setState(() {
        comments = c;
        commentsBusy = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          commentsBusy = false;
          commentError = 'Comments are offline — check connection.';
        });
      }
    }
  }

  Future<void> _postComment() async {
    final text = _commentCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() => commentError = 'Posting…');
    try {
      await Api.postComment(widget.animeId, text);
      _commentCtrl.clear();
      if (mounted) setState(() => commentError = '');
      await _loadComments();
    } catch (e) {
      if (mounted) setState(() => commentError = 'Post failed: $e');
    }
  }

  Future<void> _rate(int s) async {
    setState(() => myScore = s);
    try {
      await Api.rate(widget.animeId, s);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Rated $s/10 — thanks!')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Rating failed: $e')));
      }
    }
  }

  /// Opens the selected episodes back-to-back (Stream mode).
  Future<void> _playSelected() async {
    if (selected.isEmpty) return;
    final eps = selected.toList()..sort();
    final title = (info['title'] ?? widget.title).toString();
    final sources = <EpisodeSource>[];
    for (final ep in eps) {
      final bundle = await _sourcesFor(ep);
      currentEpisode = ep;
      if (bundle == null) continue;
      _applyAudioAvailability(bundle);
      final list = await _streamSources(ep, bundle);
      if (list.isEmpty) continue;
      sources.add(EpisodeSource(
        url: list.first.url,
        mirrors: list.skip(1).map((s) => s.url).toList(),
        label: '$title — Ep $ep (${_sourceAudio(bundle).toUpperCase()})',
        animeId: widget.animeId,
        episode: ep,
        animeTitle: title,
        image: (info['image'] ?? '').toString(),
        height: list.first.height,
      ));
    }
    if (!mounted) return;
    if (sources.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'No playable stream resolved for the picked episodes — try again.')));
      return;
    }
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => PlayerScreen(
                url: sources.first.url,
                label: sources.first.label,
                playlist: sources,
                onOpenAnime: _openAnime,
                animeId: widget.animeId,
                audio: audio,
                onAudioSwitch: _audioSwitchInPlayer)));
    _loadViewingState();
  }

  /// Which of the two app modes we are in right now (stream / download).
  String mode = AppMode.stream;
  int? currentEpisode;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (mode != appMode.value) mode = appMode.value;
  }

  /// Resolved episode bundles, memoised per episode + audio.
  /// Also carries the phase where bundles are reused instantly for instant
  /// switching, and the next episode is warmed in the background.
  final Map<String, Map<String, dynamic>> _sourceCache = {};

  /// Episode sources, memoised. A resolved bundle is reused instantly so
  /// switching episodes never re-hits the network, and the next episode is
  /// warmed in the background so the following tap plays immediately.
  Future<Map<String, dynamic>?> _sourcesFor(int ep) async {
    final key = '${widget.animeId}|$ep|$audio';
    final cached = _sourceCache[key];
    if (cached != null) return cached;
    try {
      final bundle = await Api.episodeSources(widget.animeId, ep, audio);
      _sourceCache[key] = bundle;
      _applyAudioAvailability(bundle);
      _prefetchNext(ep);
      return bundle;
    } catch (_) {
      return null;
    }
  }

  /// Pre-resolves the current episode's bundle while the user is reading the
  /// synopsis. The server also caches it, so tapping Play or Download no
  /// longer waits on a cold provider scrape.
  Future<void> _warmFirstEpisode() async {
    final ep = resumeEp ?? 1;
    if (ep < 1) return;
    final key = '${widget.animeId}|$ep|$audio';
    if (_sourceCache.containsKey(key)) return;
    try {
      final bundle = await Api.episodeSources(widget.animeId, ep, audio);
      _sourceCache[key] = bundle;
      _applyAudioAvailability(bundle);
    } catch (_) {}
  }

  /// Warm the cache for the following episode in the background (staggered so
  /// it never competes with the episode the user is actually starting).
  void _prefetchNext(int ep) {
    if (dataSaver) return;
    final next = ep + 1;
    if (totalEps > 0 && next > totalEps) return;
    final key = '${widget.animeId}|$next|$audio';
    if (_sourceCache.containsKey(key)) return;
    Future<void>.delayed(const Duration(milliseconds: 400), () async {
      try {
        _sourceCache[key] =
            await Api.episodeSources(widget.animeId, next, audio);
      } catch (_) {}
    });
  }

  static const _downloadPrefs = {
    'ask',
    'best',
    'smallest',
    '360',
    '480',
    '720',
    '1080',
  };

  /// Runtime of one episode in minutes from the catalogue ("24m" -> 24).
  int get _episodeMinutes {
    final raw = (info['duration'] ?? '').toString().toLowerCase();
    final match = RegExp(r'(\d+)\s*h').firstMatch(raw);
    if (match != null) {
      final hours = int.tryParse(match.group(1)!) ?? 0;
      final mins = RegExp(r'(\d+)\s*m').firstMatch(raw);
      return hours * 60 +
          (mins == null ? 0 : int.tryParse(mins.group(1)!) ?? 0);
    }
    final minsOnly = RegExp(r'(\d+)').firstMatch(raw);
    return minsOnly == null ? 0 : int.tryParse(minsOnly.group(1)!) ?? 0;
  }

  Future<String> _downloadPref() async {
    final p = await SharedPreferences.getInstance();
    final value = p.getString('download_quality') ?? '720';
    return _downloadPrefs.contains(value) ? value : '720';
  }

  /// Shows the real file sizes/labels the servers resolved and lets the user
  /// pick one (used when the preference is "Ask").
  /// Always-available quality picker, so the download size is a choice on the
  /// anime page instead of something buried in Settings.
  Future<void> _pickDownloadQuality() async {
    const options = <(String, String, String)>[
      (
        'smallest',
        'Smallest published file',
        'Lowest resolution the source offers'
      ),
      ('360', 'Up to 360p', 'Only if the source publishes 360p'),
      ('480', 'Up to 480p', 'Only if the source publishes 480p or lower'),
      ('720', 'Up to 720p', 'Only if the source publishes 720p or lower'),
      ('1080', 'Up to 1080p', 'Only if the source publishes 1080p or lower'),
      ('best', 'Best published', 'Highest resolution the source offers'),
      ('ask', 'Ask each time', 'Pick per episode with live file sizes'),
    ];
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: CamColors.surface,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 0, 18, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Download quality',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w800)),
                    SizedBox(height: 2),
                    Text(
                        'Only source-published qualities are downloaded — '
                        'CamAnime does not re-encode video or invent a lower '
                        'resolution. If a size is not offered, the next real '
                        'file is used.',
                        style:
                            TextStyle(color: CamColors.inkDim, fontSize: 11.5)),
                  ]),
            ),
          ),
          for (final o in options)
            ListTile(
              leading: Icon(
                  _dlQuality == o.$1
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  color:
                      _dlQuality == o.$1 ? CamColors.accent : CamColors.inkDim),
              title: Text(o.$2),
              subtitle: Text(o.$3,
                  style:
                      const TextStyle(color: CamColors.inkDim, fontSize: 11)),
              onTap: () => Navigator.pop(ctx, o.$1),
            ),
          const SizedBox(height: 6),
        ]),
      ),
    );
    if (chosen == null || !mounted) return;
    final p = await SharedPreferences.getInstance();
    await p.setString('download_quality', chosen);
    if (!mounted) return;
    setState(() => _dlQuality = chosen);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Downloads will use ${downloadQualityLabel(chosen).toLowerCase()}.'),
        duration: const Duration(seconds: 2)));
  }

  Future<DownloadOption?> _chooseDownload(List<DownloadOption> options) {
    if (options.length == 1) return Future.value(options.first);
    // Ask the servers for the real file size of every option at once, so the
    // user picks on resolution *and* download size instead of guessing.
    final sizes = {for (final o in options) o.url: _remoteSize(o.url)};
    return showModalBottomSheet<DownloadOption>(
      context: context,
      backgroundColor: CamColors.surface,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 0, 18, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Download quality',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w800)),
                    SizedBox(height: 2),
                    Text(
                        'Real source files only — these are every quality '
                        'the provider publishes for this episode',
                        style:
                            TextStyle(color: CamColors.inkDim, fontSize: 11.5)),
                  ]),
            ),
          ),
          for (final option in options)
            ListTile(
              leading: const Icon(Icons.high_quality_rounded,
                  color: CamColors.accent),
              title: Text(option.qualityLabel),
              subtitle: Text(
                '${option.audio.toUpperCase()} · ${option.label}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: FutureBuilder<int?>(
                future: sizes[option.url],
                builder: (_, snapshot) {
                  final bytes = snapshot.data;
                  final sizeLabel = bytes != null
                      ? compactBytes(bytes)
                      : snapshot.connectionState == ConnectionState.done
                          ? 'size ?'
                          : '…';
                  return Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (option.isHd)
                        const Text('HD',
                            style: TextStyle(
                                color: CamColors.accent,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800)),
                      Text(sizeLabel,
                          style: const TextStyle(
                              color: CamColors.inkDim,
                              fontSize: 11,
                              fontWeight: FontWeight.w700)),
                    ],
                  );
                },
              ),
              onTap: () => Navigator.pop(ctx, option),
            ),
          ListTile(
            leading: const Icon(Icons.close_rounded),
            title: const Text('Cancel'),
            onTap: () => Navigator.pop(ctx),
          ),
          const SizedBox(height: 6),
        ]),
      ),
    );
  }

  /// Real size of a download option. The API returns Content-Length for direct
  /// MP4 files and for stitched HLS episodes; when a CDN refuses HEAD we ask for
  /// a single byte and read the total from Content-Range.
  Future<int?> _remoteSize(String url) async {
    final client = http.Client();
    try {
      final target = Uri.parse(Api.abs(url));
      final headers = await Api.headers();
      final request = http.Request('HEAD', target)..headers.addAll(headers);
      final response =
          await client.send(request).timeout(const Duration(seconds: 20));
      await response.stream.drain<void>();
      final length = int.tryParse(response.headers['content-length'] ?? '');
      if (length != null && length > 0) return length;
      // The stitcher ignores Range and would transfer the whole episode, so a
      // missing HEAD size there is reported as unavailable rather than fetched.
      if (target.path.endsWith('/download/hls')) return null;
      final probe = http.Request('GET', target)
        ..headers.addAll({...headers, 'Range': 'bytes=0-0'});
      final ranged =
          await client.send(probe).timeout(const Duration(seconds: 20));
      await ranged.stream.drain<void>();
      final range = ranged.headers['content-range'] ?? '';
      final match = RegExp(r'/(\d+)\s*$').firstMatch(range);
      if (match != null) return int.tryParse(match.group(1)!);
      final rangedLength = int.tryParse(ranged.headers['content-length'] ?? '');
      return (rangedLength != null && rangedLength > 1) ? rangedLength : null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  Future<void> _openTrailer() async {
    if (trailerBusy) return;
    var id = trailerId;
    if (id.isEmpty) {
      setState(() => trailerBusy = true);
      try {
        id = await Api.trailer(
                widget.animeId, (info['title'] ?? widget.title).toString()) ??
            '';
        trailerId = id;
      } catch (_) {}
      if (!mounted) return;
      setState(() => trailerBusy = false);
    }
    if (!mounted) return;
    if (id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No official YouTube trailer found for this title.')));
      return;
    }
    _showTrailer(id);
  }

  void _showTrailer(String id) {
    final watch = Uri.parse('https://www.youtube.com/watch?v=$id');
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: CamColors.surface,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Image.network(
                  'https://img.youtube.com/vi/$id/hqdefault.jpg',
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    color: CamColors.surfaceAlt,
                    alignment: Alignment.center,
                    child: const Icon(Icons.movie_outlined,
                        size: 34, color: CamColors.inkDim),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Official YouTube trailer',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            ),
            const Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.only(top: 3),
                child: Text(
                    'Plays on YouTube — CamAnime adds no ads of its own.',
                    style: TextStyle(color: CamColors.inkDim, fontSize: 11.5)),
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: CamColors.accent,
                  foregroundColor: Colors.black,
                  textStyle: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w800),
                ),
                onPressed: () async {
                  Navigator.pop(ctx);
                  var opened = false;
                  try {
                    opened = await launchUrl(watch,
                        mode: LaunchMode.inAppBrowserView);
                  } catch (_) {}
                  if (!opened) {
                    try {
                      await launchUrl(watch,
                          mode: LaunchMode.externalApplication);
                    } catch (_) {}
                  }
                },
                icon: const Icon(Icons.play_arrow_rounded, size: 20),
                label: const Text('Watch on YouTube'),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  void _openAnime(String id, String title) {
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => DetailScreen(animeId: id, title: title)));
  }

  Future<List<EpisodeSource>> _streamSources(
      int ep, Map<String, dynamic> bundle) async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString('stream_quality') ?? 'auto';
    // Data saver streams the lowest genuine rendition at or below 480p. If the
    // provider publishes nothing that low, the normal ordering still applies.
    final pref = (p.getBool('app_data_saver') ?? false) ? '480' : saved;
    return episodeSourcesFromBundle(
      bundle,
      animeId: widget.animeId,
      episode: ep,
      animeTitle: (info['title'] ?? widget.title).toString(),
      image: (info['image'] ?? '').toString(),
      preferredAudio: audio,
      absolute: Api.abs,
      qualityPreference: pref,
    );
  }

  /// Next episode for auto-next: its preferred source plus its other servers
  /// as mirrors, so a dead provider is still skipped automatically.
  Future<EpisodeSource?> _sourceForEpisode(int ep) async {
    final bundle = await _sourcesFor(ep);
    if (bundle == null) return null;
    final list = await _streamSources(ep, bundle);
    if (list.isEmpty) return null;
    return list.first
        .copyWith(mirrors: list.skip(1).map((s) => s.url).toList());
  }

  Future<void> _play(int ep) async {
    final animeId = int.tryParse(widget.animeId) ?? 0;
    final title = (info['title'] ?? widget.title).toString();
    final task = DownloadManager.instance.taskFor(animeId, ep);
    final local =
        task == null ? null : DownloadManager.instance.playableFile(task);
    if (local != null) {
      final partial = local.path.endsWith('.part');
      if (!mounted) return;
      final suffix = partial ? ' (downloading)' : ' (offline)';
      // Saved episodes for this anime play back-to-back offline, and when the
      // on-disk folder runs out the player keeps the series going by streaming
      // the next episode.
      final queue = <EpisodeSource>[];
      var start = 0;
      for (final saved in DownloadManager.instance.completed) {
        if (saved.animeId != animeId) continue;
        final playable = DownloadManager.instance.playableFile(saved);
        if (playable == null) continue;
        if (saved.episode == ep) start = queue.length;
        queue.add(EpisodeSource(
          url: playable.path,
          label: '$title — Ep ${saved.episode}',
          animeId: widget.animeId,
          animeTitle: title,
          episode: saved.episode,
          image: saved.image,
          height: saved.height,
        ));
      }
      queue.sort((a, b) => (a.episode ?? 0).compareTo(b.episode ?? 0));
      start = queue.indexWhere((s) => s.episode == ep);
      if (start < 0) start = 0;
      Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => PlayerScreen(
                    url: local.path,
                    label: '$title — Ep $ep$suffix',
                    localFile: true,
                    episode: ep,
                    playlist: queue,
                    startIndex: start,
                    fetchEpisode: _sourceForEpisode,
                    onOpenAnime: _openAnime,
                    animeId: widget.animeId,
                    audio: audio,
                    onAudioSwitch: _audioSwitchInPlayer,
                  )));
      return;
    }
    final bundle = await _sourcesFor(ep);
    if (!mounted) return;
    if (bundle == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not reach streaming servers — try again.')));
      return;
    }
    _applyAudioAvailability(bundle);
    _noteAudioFallback(bundle, ep);
    final sources = await _streamSources(ep, bundle);
    if (!mounted) return;
    if (sources.isEmpty) {
      final embed = _providerEmbed(bundle);
      if (embed != null) {
        if (mounted) {
          setState(() => dlStatus =
              'Episode $ep uses a provider player — opening it now.');
        }
        await _openProviderEmbed(embed);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No playable source was returned for this episode. '
                'Try another episode or server.')));
      }
      return;
    }
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => PlayerScreen(
                  url: sources.first.url,
                  mirrors: sources.skip(1).map((s) => s.url).toList(),
                  variants: sources,
                  episode: ep,
                  resume: true,
                  fetchEpisode: _sourceForEpisode,
                  label:
                      '$title — Ep $ep (${_sourceAudio(bundle).toUpperCase()})',
                  onOpenAnime: _openAnime,
                  animeId: widget.animeId,
                  audio: audio,
                  onAudioSwitch: _audioSwitchInPlayer,
                )));
  }

  Future<void> _downloadEp(int ep) async {
    // Respond to the tap immediately; resolving servers can take a moment.
    if (mounted) {
      setState(() => dlStatus = 'Episode $ep: finding the best file…');
    }
    try {
      final bundle = await _sourcesFor(ep);
      if (bundle == null) throw const HttpException('No servers reachable');
      _applyAudioAvailability(bundle);
      if (bundle['audio_fallback'] == true && audio == 'dub' && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No provider dub for this episode — a SUB file will '
                'be saved.')));
      }
      final options =
          downloadOptions(bundle, preferredAudio: audio, absolute: Api.abs);
      if (options.isEmpty) {
        throw const HttpException(
            'No direct video file for this episode — it is stream-only.');
      }
      final pref = await _downloadPref();
      final chosen = pref == 'ask'
          ? await _chooseDownload(options)
          : pickDownloadOption(options, pref);
      if (chosen == null || !mounted) return;
      final task = await _queueEpisode(ep, bundle, option: chosen);
      if (!mounted) return;
      // The real size arrives with the response headers. Wait briefly so the
      // confirmation shows the actual file size instead of a guessed one.
      for (var i = 0; i < 10 && task.total <= 0; i++) {
        if (task.stage == DownloadStage.failed) break;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      final size = task.total > 0 ? ' · ${compactBytes(task.total)}' : '';
      if (!mounted) return;
      setState(
          () => dlStatus = 'Episode $ep queued$size — it starts immediately.');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Episode $ep added$size to downloads. '
              'It appears in Library now.')));
    } catch (e) {
      if (mounted) setState(() => dlStatus = 'Episode $ep: $e');
    }
  }

  Future<DownloadTask> _queueEpisode(int ep, Map<String, dynamic> bundle,
      {DownloadOption? option}) async {
    final options =
        downloadOptions(bundle, preferredAudio: audio, absolute: Api.abs);
    final pref = await _downloadPref();
    final chosen =
        option ?? pickDownloadOption(options, pref == 'ask' ? '720' : pref);
    if (chosen == null) {
      throw const HttpException(
          'No direct video file for this episode — it is stream-only.');
    }
    final rawPoster = (info['image'] ?? '').toString().trim();
    return DownloadManager.instance.enqueue(
      animeTitle: (info['title'] ?? widget.title).toString(),
      animeId: int.tryParse(widget.animeId) ?? 0,
      episode: ep,
      audio: chosen.audio,
      url: chosen.url,
      // Absolute URL: the notification host fetches this directly, without the
      // app's API headers, so a relative path would never resolve to artwork.
      image: rawPoster.isEmpty ? '' : Api.abs(rawPoster),
      season: (info['season'] ?? '').toString(),
      height: chosen.height,
      durationMinutes: _episodeMinutes,
    );
  }

  Future<void> _downloadSelected() async {
    if (selected.isEmpty) return;
    final eps = selected.toList()..sort();
    var queued = 0;
    setState(() => dlStatus = 'Queueing ${eps.length} episodes…');
    for (final ep in eps) {
      try {
        final bundle = await _sourcesFor(ep);
        if (bundle == null) continue;
        await _queueEpisode(ep, bundle);
        queued++;
      } catch (_) {
        // The rest of the queue is still processed.
      }
    }
    if (!mounted) return;
    setState(() {
      dlStatus = '$queued of ${eps.length} episodes queued — see My Library.';
      selected.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            '$queued episode(s) downloading in the background. Playable parts show in Library.')));
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = (info['title'] ?? widget.title).toString();
    final poster = (info['image'] ?? '').toString();
    final backdrop = (info['banner'] ?? poster).toString();
    final genres = ((info['genres'] as List?) ?? const [])
        .map((e) => e.toString())
        .where((e) => e.isNotEmpty)
        .toList();
    final current = currentEpisode ?? resumeEp ?? (totalEps > 0 ? 1 : null);
    final watchLabel = currentEpisode == null && resumeEp != null
        ? 'Continue EP $resumeEp'
        : (totalEps > 1 ? 'Watch EP ${current ?? 1}' : 'Watch now');

    return Scaffold(
      backgroundColor: CamColors.bg,
      body: loading
          ? const Center(
              child: CircularProgressIndicator(color: CamColors.accent))
          : Stack(children: [
              ListView(
                padding: EdgeInsets.zero,
                physics: const BouncingScrollPhysics(),
                children: [
                  _DetailHero(
                    title: title,
                    nativeTitle: (info['title_native'] ?? '').toString(),
                    backdrop: backdrop,
                    poster: poster,
                    rating: (info['rating'] ?? '').toString(),
                    year: (info['year'] ?? '').toString(),
                    format: (info['format'] ?? '').toString(),
                    status: (info['status'] ?? '').toString(),
                    episodes: totalEps,
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (genres.isNotEmpty) _GenreRow(genres: genres),
                        if ((info['description'] ?? '')
                            .toString()
                            .isNotEmpty) ...[
                          const SizedBox(height: 14),
                          _Synopsis(text: info['description'].toString()),
                        ],
                        const SizedBox(height: 16),
                        _ActionRow(
                          watchLabel: watchLabel,
                          myScore: myScore,
                          onWatch:
                              current == null ? null : () => _play(current),
                          onDownload: current == null
                              ? null
                              : () => _downloadEp(current),
                          onRate: _rateSheet,
                          saved: _saved,
                          onSave: _toggleWatch,
                        ),
                        const SizedBox(height: 10),
                        _DownloadQualityRow(
                          value: _dlQuality,
                          onTap: _pickDownloadQuality,
                        ),
                        const SizedBox(height: 16),
                        _AudioSeasonBar(
                          audio: audio,
                          dubAvailable: _dubAvailable,
                          onAudio: _setAudio,
                          currentId: widget.animeId,
                          currentTitle: title,
                          seasons: seasons,
                          onSeason: _openSeason,
                        ),
                        if (_dubAvailable == false) ...[
                          const SizedBox(height: 6),
                          const Text(
                            'No provider dub is published for this title yet. '
                            'SUB is used automatically when a DUB track does '
                            'not exist.',
                            style: TextStyle(
                                color: CamColors.inkDim,
                                fontSize: 10.5,
                                height: 1.4),
                          ),
                        ],
                        const SizedBox(height: 24),
                        ..._episodeSection(),
                        const SizedBox(height: 28),
                        const _SectionHeading(
                          eyebrow: 'Picked from the catalogue',
                          title: 'More like this',
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 236,
                          child: _RelatedPane(
                            animeId: widget.animeId,
                            genres: genres,
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) => const BrowseScreen())),
                            child: const Text('More'),
                          ),
                        ),
                        if (seasons.isNotEmpty) ...[
                          const SizedBox(height: 26),
                          _SectionHeading(
                            eyebrow: '${seasons.length} related titles',
                            title: 'Seasons & side stories',
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            height: 214,
                            child: _SeasonsRail(
                              seasons: seasons,
                              onOpen: _openSeason,
                            ),
                          ),
                        ],
                        const SizedBox(height: 26),
                        _SectionHeading(
                          eyebrow: 'Community',
                          title: 'Comments',
                          trailing: TextButton(
                            onPressed: _loadComments,
                            child: const Text('Refresh'),
                          ),
                        ),
                        _CommentsPane(
                          comments: comments,
                          busy: commentsBusy,
                          error: commentError,
                          controller: _commentCtrl,
                          onPost: _postComment,
                          onRefresh: _loadComments,
                        ),
                        const SizedBox(height: 40),
                      ],
                    ),
                  ),
                ],
              ),
              Positioned(
                top: MediaQuery.paddingOf(context).top + 8,
                left: 10,
                child: _RoundButton(
                  icon: Icons.arrow_back_rounded,
                  tooltip: 'Back',
                  onTap: () => Navigator.maybePop(context),
                ),
              ),
              Positioned(
                top: MediaQuery.paddingOf(context).top + 8,
                right: 10,
                child: _RoundButton(
                  icon: trailerBusy
                      ? Icons.hourglass_top_rounded
                      : Icons.movie_creation_outlined,
                  tooltip: 'Watch trailer',
                  onTap: _openTrailer,
                ),
              ),
            ]),
    );
  }

  List<Widget> _episodeSection() {
    return [
      Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        runSpacing: 2,
        children: [
          const Text(
            'Episodes',
            style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.2),
          ),
          Text(
            totalEps > 0 ? '1–$totalEps' : 'not listed',
            style: const TextStyle(color: CamColors.inkDim, fontSize: 11.5),
          ),
          TextButton(
            onPressed: totalEps == 0 ? null : () => _selectAll(true),
            style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 6)),
            child: const Text('Select all', style: TextStyle(fontSize: 11.5)),
          ),
          TextButton(
            onPressed: selected.isEmpty ? null : () => _selectAll(false),
            style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 6)),
            child: const Text('Deselect all', style: TextStyle(fontSize: 11.5)),
          ),
        ],
      ),
      const SizedBox(height: 4),
      if (selected.isNotEmpty) ...[
        _SelectionBar(
          count: selected.length,
          onPlayQueue: _playSelected,
          onDownload: _downloadSelected,
          onClear: () => setState(selected.clear),
        ),
        const SizedBox(height: 10),
      ],
      EpisodeBoard(
        animeId: int.tryParse(widget.animeId) ?? 0,
        totalEpisodes: totalEps,
        currentEpisode: currentEpisode,
        selected: selected,
        previews: previews,
        progress: watch,
        onPlay: _play,
        onToggleSelect: (ep, sel) => setState(() {
          if (sel) {
            selected.add(ep);
          } else {
            selected.remove(ep);
          }
        }),
        onDownload: _downloadEp,
        imageBuilder: (url) => CachedPosterImage(url: url),
      ),
      if (dlStatus.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(dlStatus,
            style: const TextStyle(color: CamColors.inkDim, fontSize: 11.5)),
      ],
    ];
  }

  void _selectAll(bool all) {
    setState(() {
      selected.clear();
      if (all && totalEps > 0) {
        selected.addAll(List<int>.generate(totalEps, (i) => i + 1));
      }
    });
  }

  void _setAudio(String value) {
    if (value == 'dub' && _dubAvailable == false) return;
    setState(() => audio = value);
    SharedPreferences.getInstance()
        .then((p) => p.setString('app_audio', value));
  }

  /// Re-fetches the current episode's sources with a new audio and returns the
  /// best URL for the player. Used by the in-player audio switch.
  Future<String?> _audioSwitchInPlayer(String newAudio) async {
    if (widget.animeId.isEmpty) return null;
    final ep = currentEpisode ?? 1;
    try {
      final bundle = await Api.episodeSources(widget.animeId, ep, newAudio);
      _applyAudioAvailability(bundle);
      final list = await _streamSourcesForBundle(bundle, ep);
      if (list.isEmpty) return null;
      return list.first.url;
    } catch (_) {
      return null;
    }
  }

  Future<List<EpisodeSource>> _streamSourcesForBundle(
      Map<String, dynamic> bundle, int ep) async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString('stream_quality') ?? 'auto';
    final pref = (p.getBool('app_data_saver') ?? false) ? '480' : saved;
    return episodeSourcesFromBundle(
      bundle,
      animeId: widget.animeId,
      episode: ep,
      animeTitle: (info['title'] ?? widget.title).toString(),
      image: (info['image'] ?? '').toString(),
      preferredAudio: audio,
      absolute: Api.abs,
      qualityPreference: pref,
    );
  }

  void _openSeason(String id, String title) {
    if (id == widget.animeId || id.isEmpty) return;
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => DetailScreen(animeId: id, title: title)));
  }

  /// Bookmark for the Library's Watchlist tab.
  Future<void> _toggleWatch() async {
    final title = (info['title'] ?? widget.title).toString();
    final saved = await Watchlist.toggle(
      animeId: widget.animeId,
      title: title,
      image: (info['image'] ?? '').toString(),
      episodes: int.tryParse('${info['episodes'] ?? 0}') ?? 0,
    );
    if (!mounted) return;
    setState(() => _saved = saved);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(saved
          ? 'Added to watchlist — find it in Library'
          : 'Removed from watchlist'),
      duration: const Duration(seconds: 2),
    ));
  }

  void _rateSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: CamColors.surface,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 2, 20, 28),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Rate this anime',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              const Text('Your score helps other viewers.',
                  style: TextStyle(color: CamColors.inkDim, fontSize: 11.5)),
              const SizedBox(height: 16),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (var s = 1; s <= 10; s++)
                  ChoiceChip(
                    label: Text('$s'),
                    selected: myScore == s,
                    onSelected: (_) {
                      Navigator.pop(ctx);
                      _rate(s);
                    },
                  ),
              ]),
            ]),
      ),
    );
  }
}

class _RelatedPane extends StatefulWidget {
  final String animeId;
  final List<String> genres;
  const _RelatedPane({required this.animeId, required this.genres});
  @override
  State<_RelatedPane> createState() => _RelatedPaneState();
}

class _RelatedPaneState extends State<_RelatedPane> {
  List items = [];
  bool busy = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await Api.catalogHome();
      final data = (result['catalog'] as Map?)?.cast<String, dynamic>() ??
          <String, dynamic>{};
      final pool = [
        ...((data['trending'] as List?) ?? []),
        ...((data['popular'] as List?) ?? []),
        ...((data['top_rated'] as List?) ?? []),
      ];
      pool.shuffle();
      if (!mounted) return;
      setState(() {
        items = pool
            .where((e) => e is Map && '${e['id']}' != widget.animeId)
            .take(12)
            .toList();
        busy = false;
      });
    } catch (_) {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const Center(
          child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: CamColors.accent)));
    }
    if (items.isEmpty) {
      return const Center(
          child: Text('No recommendations yet.',
              style: TextStyle(color: CamColors.inkDim, fontSize: 12)));
    }
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(width: 10),
      itemBuilder: (_, i) => PosterCard(item: items[i] as Map, width: 112),
    );
  }
}

class _CommentsPane extends StatelessWidget {
  final List comments;
  final bool busy;
  final String error;
  final TextEditingController controller;
  final VoidCallback onPost;
  final VoidCallback onRefresh;
  const _CommentsPane(
      {required this.comments,
      required this.busy,
      required this.error,
      required this.controller,
      required this.onPost,
      required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: controller,
              style: const TextStyle(fontSize: 12.5),
              decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Add a comment…',
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 12, vertical: 12)),
              onSubmitted: (_) => onPost(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: CamColors.accent,
                foregroundColor: Colors.black,
                minimumSize: const Size(0, 42),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                textStyle: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w800)),
            onPressed: onPost,
            child: const Text('Post'),
          ),
        ]),
      ),
      if (error.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(error,
              style: const TextStyle(color: CamColors.danger, fontSize: 11.5)),
        ),
      if (busy)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(
              child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: CamColors.accent))),
        )
      else if (comments.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Row(children: [
            const Icon(Icons.forum_outlined, size: 18, color: CamColors.inkDim),
            const SizedBox(width: 8),
            const Expanded(
                child: Text('No comments yet — start the conversation.',
                    style: TextStyle(color: CamColors.inkDim, fontSize: 11.5))),
            TextButton(onPressed: onRefresh, child: const Text('Refresh')),
          ]),
        )
      else
        ...comments.take(40).map((raw) {
          final c = raw is Map ? raw : const {};
          final name = (c['user'] ?? 'Guest').toString();
          final text = (c['text'] ?? c['sticker'] ?? '').toString();
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              CircleAvatar(
                radius: 15,
                backgroundColor: CamColors.surfaceAlt,
                child: Text(name.characters.firstOrNull?.toUpperCase() ?? 'G',
                    style: const TextStyle(
                        color: CamColors.accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w800)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 2),
                      Text(text,
                          style: const TextStyle(
                              color: CamColors.inkDim,
                              fontSize: 12,
                              height: 1.4)),
                    ]),
              ),
              const SizedBox(width: 8),
              Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.favorite_rounded,
                    size: 12, color: CamColors.danger),
                const SizedBox(width: 3),
                Text('${c['likes'] ?? 0}',
                    style: const TextStyle(
                        color: CamColors.inkDim, fontSize: 10.5)),
              ]),
            ]),
          );
        }),
    ]);
  }
}

// ── Player (website's own MP4/HLS streams, in-app) ──────
// ── Search (posters + genre filter) ─────────────────────
class SearchTab extends StatefulWidget {
  const SearchTab({super.key});
  @override
  State<SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<SearchTab> {
  final c = TextEditingController();
  List results = [];
  List genres = [];
  String? genreSlug;
  bool loading = false;
  bool genreBusy = false;

  /// Catalogue filters that sit under the search field. They narrow a text
  /// query and, when the field is empty, browse the catalogue with them.
  static const _sorts = <String, String>{
    'popular': 'Popular',
    'rating': 'Top rated',
    'recent': 'Newest',
    'alphabetical': 'A–Z',
  };
  static const _formats = <String, String>{
    '': 'Any type',
    'TV': 'Series',
    'MOVIE': 'Movies',
    'ONA': 'ONA',
  };
  String sortKey = 'popular';
  String formatKey = '';
  bool olderOnly = false;
  bool filtersOpen = false;

  Timer? _debounce;
  int _requestId = 0;
  String? error;

  @override
  void initState() {
    super.initState();
    _loadGenres();
  }

  Future<void> _loadGenres() async {
    try {
      final g = await Api.genres();
      if (mounted) setState(() => genres = g);
    } catch (_) {}
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _requestId++;
    c.dispose();
    super.dispose();
  }

  void _onQueryChanged(String _) {
    _debounce?.cancel();
    final query = c.text.trim();
    if (query.length < 2) {
      setState(() {
        if (genreSlug == null) results = [];
        error = null;
        loading = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), go);
  }

  Future<void> go() async {
    final query = c.text.trim();
    if (query.length < 2) {
      return;
    }
    final requestId = ++_requestId;
    setState(() {
      loading = true;
      error = null;
      genreSlug = null;
    });
    try {
      final found = await Api.search(query);
      if (!mounted || requestId != _requestId) {
        return;
      }
      final refined = _refine(found);
      setState(() {
        results = refined;
        error = refined.isEmpty
            ? (found.isEmpty
                ? 'No matching anime found.'
                : 'No matches with these filters.')
            : null;
      });
    } catch (_) {
      if (!mounted || requestId != _requestId) {
        return;
      }
      setState(() {
        results = [];
        error = 'Search is unavailable. Check your connection and try again.';
      });
    } finally {
      if (mounted && requestId == _requestId) setState(() => loading = false);
    }
  }

  /// Applies the visible filters to a result list. Sorting is local because the
  /// search endpoint ranks by relevance; a pure filter browse is served by the
  /// catalogue endpoint instead, which honours the sort server-side.
  List _refine(List rows) {
    var out = rows.whereType<Map>().toList();
    if (formatKey.isNotEmpty) {
      out = out
          .where(
              (r) => (r['format'] ?? '').toString().toUpperCase() == formatKey)
          .toList();
    }
    if (olderOnly) {
      out = out
          .where((r) => (int.tryParse('${r['year'] ?? ''}') ?? 9999) < 2015)
          .toList();
    }
    int year(Map r) => int.tryParse('${r['year'] ?? ''}') ?? 0;
    int score(Map r) =>
        (double.tryParse('${r['score'] ?? r['rating'] ?? 0}') ?? 0).round();
    switch (sortKey) {
      case 'rating':
        out.sort((a, b) => score(b).compareTo(score(a)));
      case 'recent':
        out.sort((a, b) => year(b).compareTo(year(a)));
      case 'alphabetical':
        out.sort((a, b) => (a['title'] ?? '')
            .toString()
            .toLowerCase()
            .compareTo((b['title'] ?? '').toString().toLowerCase()));
    }
    return out;
  }

  /// Filter-only browsing: no text query, so the catalogue endpoint is asked
  /// directly and honours genre, sort, format and year.
  Future<void> _browseFilters() async {
    if (c.text.trim().length >= 2) {
      await go();
      return;
    }
    final requestId = ++_requestId;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final found = await Api.browse(
        genre: genreSlug ?? '',
        sort: sortKey,
        limit: 36,
        format: formatKey,
        yearBefore: olderOnly ? 2015 : null,
      );
      if (!mounted || requestId != _requestId) return;
      setState(() {
        results = found;
        error = found.isEmpty ? 'Nothing matches these filters yet.' : null;
      });
    } catch (_) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        results = [];
        error = 'Filters are unavailable. Check your connection.';
      });
    } finally {
      if (mounted && requestId == _requestId) setState(() => loading = false);
    }
  }

  Future<void> _pickGenre(String? slug) async {
    setState(() {
      genreSlug = slug;
      genreBusy = slug != null;
      error = null;
      if (slug == null && c.text.trim().length < 2) results = [];
    });
    if (slug == null) return;
    try {
      final found = await Api.genreAnime(slug);
      if (!mounted) return;
      setState(() {
        results = found;
        genreBusy = false;
        error = found.isEmpty ? 'No titles in this genre yet.' : null;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          genreBusy = false;
          error = 'Genre is unavailable. Check your connection.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: c,
                  textInputAction: TextInputAction.search,
                  onChanged: _onQueryChanged,
                  onSubmitted: (_) {
                    _debounce?.cancel();
                    go();
                  },
                  decoration: const InputDecoration(
                      hintText: 'Search every anime…',
                      prefixIcon: Icon(Icons.search)),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [amber, pink]),
                    borderRadius: BorderRadius.circular(14)),
                child: IconButton(
                    icon: const Icon(Icons.arrow_forward, color: Colors.black),
                    onPressed: go),
              ),
            ]),
          ),
          // Genres sit directly under the search field, with the catalogue
          // filters one tap away so search and browse share the same controls.
          if (genres.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: genres.length + 1,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  if (i == 0) {
                    return ChoiceChip(
                        label: const Text('All genres'),
                        selected: genreSlug == null,
                        onSelected: (_) => _pickGenre(null));
                  }
                  final g = genres[i - 1] as Map;
                  final slug = (g['slug'] ?? '').toString();
                  return ChoiceChip(
                      label: Text((g['name'] ?? slug).toString()),
                      selected: genreSlug == slug,
                      onSelected: (_) => _pickGenre(slug));
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Row(children: [
              TextButton.icon(
                onPressed: () => setState(() => filtersOpen = !filtersOpen),
                icon: Icon(
                    filtersOpen ? Icons.filter_alt : Icons.filter_alt_outlined,
                    size: 18),
                label: const Text('Filters'),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '${_sorts[sortKey] ?? 'Popular'} · '
                  '${_formats[formatKey] ?? 'Any type'}'
                  '${olderOnly ? ' · Older classics' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: muted, fontSize: 11.5),
                ),
              ),
              if (filtersOpen)
                TextButton(
                  onPressed: () {
                    setState(() {
                      sortKey = 'popular';
                      formatKey = '';
                      olderOnly = false;
                    });
                    _browseFilters();
                  },
                  child: const Text('Reset'),
                ),
            ]),
          ),
          if (filtersOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(spacing: 7, runSpacing: 7, children: [
                      for (final entry in _sorts.entries)
                        ChoiceChip(
                          label: Text(entry.value),
                          selected: sortKey == entry.key,
                          onSelected: (_) {
                            setState(() => sortKey = entry.key);
                            _browseFilters();
                          },
                        ),
                    ]),
                    const SizedBox(height: 8),
                    Wrap(spacing: 7, runSpacing: 7, children: [
                      for (final entry in _formats.entries)
                        ChoiceChip(
                          label: Text(entry.value),
                          selected: formatKey == entry.key,
                          onSelected: (_) {
                            setState(() => formatKey = entry.key);
                            _browseFilters();
                          },
                        ),
                      FilterChip(
                        label: const Text('Older classics'),
                        selected: olderOnly,
                        onSelected: (v) {
                          setState(() => olderOnly = v);
                          _browseFilters();
                        },
                      ),
                    ]),
                  ]),
            ),
          if (loading || genreBusy) const LinearProgressIndicator(color: amber),
          Expanded(
            child: results.isEmpty
                ? Center(
                    child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                        Icon(
                            error == null
                                ? Icons.search_rounded
                                : Icons.search_off,
                            size: 56,
                            color: muted),
                        const SizedBox(height: 8),
                        Text(error ?? 'Search the shared catalogue.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: muted)),
                      ]))
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount:
                            MediaQuery.sizeOf(context).width < 360 ? 2 : 3,
                        childAspectRatio: 0.56,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 12),
                    itemCount: results.length,
                    itemBuilder: (_, i) => PosterCard(
                        item: results[i] as Map, width: double.infinity),
                  ),
          ),
        ]),
      );
}

// ── Library (downloads live here + app update) ─────────
class ProfileTab extends StatefulWidget {
  const ProfileTab({super.key});
  @override
  State<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<ProfileTab> {
  final name = TextEditingController();
  int avatar = 0;
  bool online = false;
  String? customAvatarPath;
  bool customBusy = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final p = await SharedPreferences.getInstance();
    name.text = p.getString('username') ?? '';
    avatar = p.getInt('avatar_idx') ?? 0;
    final savedPath = p.getString('avatar_custom_path');
    if (savedPath != null && savedPath.isNotEmpty) {
      try {
        if (await File(savedPath).exists()) {
          customAvatarPath = savedPath;
        } else {
          await p.remove('avatar_custom_path');
        }
      } catch (_) {}
    }
    if (mounted) setState(() {});
    try {
      await Api.version();
      if (mounted) setState(() => online = true);
    } catch (_) {}
  }

  Future<void> _pickCustomPhoto() async {
    if (customBusy) return;
    setState(() => customBusy = true);
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
          source: ImageSource.gallery, maxWidth: 512, imageQuality: 85);
      if (picked == null) return;
      final dir = await getApplicationDocumentsDirectory();
      final dest = File('${dir.path}/camanime_profile.jpg');
      await File(picked.path).copy(dest.path);
      final p = await SharedPreferences.getInstance();
      await p.setString('avatar_custom_path', dest.path);
      if (mounted) setState(() => customAvatarPath = dest.path);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Profile pic updated')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not set pic: $e')));
      }
    } finally {
      if (mounted) setState(() => customBusy = false);
    }
  }

  Future<void> _removeCustomPhoto() async {
    final p = await SharedPreferences.getInstance();
    await p.remove('avatar_custom_path');
    if (customAvatarPath != null) {
      try {
        await File(customAvatarPath!).delete();
      } catch (_) {}
    }
    if (mounted) setState(() => customAvatarPath = null);
  }

  Widget _avatarImage(Map<String, dynamic> a, double radius, double iconSize) {
    if (customAvatarPath != null) {
      return CircleAvatar(
        radius: radius,
        backgroundImage: FileImage(File(customAvatarPath!)),
        backgroundColor: card2,
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: Color(a['color'] as int).withValues(alpha: 0.2),
      child: Icon(a['icon'] as IconData,
          size: iconSize, color: Color(a['color'] as int)),
    );
  }

  Future<void> _pickAvatar() async {
    final chosen = await showDialog<int>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: card,
        title: const Text('Choose profile pic'),
        content: SizedBox(
          width: 320,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.pop(context, -1),
                icon: const Icon(Icons.upload, size: 18),
                label: Text(customBusy
                    ? 'Loading…'
                    : customAvatarPath != null
                        ? 'Change custom photo'
                        : 'Upload custom photo'),
              ),
            ),
            if (customAvatarPath != null)
              TextButton.icon(
                onPressed: () => Navigator.pop(context, -2),
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('Remove custom photo'),
              ),
            const SizedBox(height: 8),
            GridView.builder(
              shrinkWrap: true,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4, crossAxisSpacing: 10, mainAxisSpacing: 10),
              itemCount: avatarPresets.length,
              itemBuilder: (_, i) {
                final preset = avatarPresets[i];
                return InkWell(
                  onTap: () => Navigator.pop(context, i),
                  child: CircleAvatar(
                    backgroundColor:
                        Color(preset['color'] as int).withValues(alpha: 0.2),
                    child: Icon(preset['icon'] as IconData,
                        color: Color(preset['color'] as int), size: 30),
                  ),
                );
              },
            ),
          ]),
        ),
      ),
    );
    if (chosen == null) return;
    if (chosen == -1) {
      await _pickCustomPhoto();
      return;
    }
    if (chosen == -2) {
      await _removeCustomPhoto();
      return;
    }
    final p = await SharedPreferences.getInstance();
    await p.setInt('avatar_idx', chosen);
    if (mounted) setState(() => avatar = chosen);
  }

  @override
  Widget build(BuildContext context) {
    final a = avatarPresets[avatar % avatarPresets.length];
    return SafeArea(
      child: ListView(padding: const EdgeInsets.only(bottom: 110), children: [
        Container(
          padding: const EdgeInsets.fromLTRB(20, 52, 20, 18),
          decoration: const BoxDecoration(
              gradient: LinearGradient(
                  colors: [Color(0xFF1A1033), bg],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight)),
          child: Row(children: [
            GestureDetector(
              onTap: customBusy ? null : _pickAvatar,
              child: Stack(children: [
                _avatarImage(a, 36, 40),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                          color: amber, shape: BoxShape.circle),
                      child: const Icon(Icons.edit,
                          size: 12, color: Colors.black)),
                ),
              ]),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name.text.isEmpty ? 'You' : name.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w900)),
                    const Text(
                        'Tap the pic to change it. Watching is free, no login needed.',
                        style: TextStyle(color: muted, fontSize: 12)),
                    const SizedBox(height: 6),
                    Row(children: [
                      Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                              color: online ? mint : pink,
                              shape: BoxShape.circle)),
                      const SizedBox(width: 6),
                      Text(online ? 'Connected to website' : 'Connecting…',
                          style: TextStyle(
                              color: online ? mint : muted,
                              fontSize: 11,
                              fontWeight: FontWeight.w700)),
                    ]),
                  ]),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(children: [
                  TextField(
                      controller: name,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                          labelText: 'Display name (for comments)',
                          prefixIcon: Icon(Icons.badge_outlined))),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                        style: FilledButton.styleFrom(
                            backgroundColor: amber,
                            foregroundColor: Colors.black),
                        onPressed: () async {
                          final p = await SharedPreferences.getInstance();
                          await p.setString('username', name.text.trim());
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text(
                                      'Name saved — it shows on your comments.')));
                        },
                        child: const Text('Save name')),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            const _AuthCard(),
            const SizedBox(height: 16),
            const Text(appCredit,
                textAlign: TextAlign.center,
                style: TextStyle(color: muted, fontSize: 12)),
          ]),
        ),
      ]),
    );
  }
}

class _AuthCard extends StatefulWidget {
  const _AuthCard();
  @override
  State<_AuthCard> createState() => _AuthCardState();
}

class _AuthCardState extends State<_AuthCard> {
  final email = TextEditingController();
  final password = TextEditingController();
  bool busy = false;
  String? who;

  @override
  void initState() {
    super.initState();
    _who();
  }

  // The website identifies the signed-in user; the app only needs the email.
  // Administrative roles are intentionally not read here: the APK has no admin
  // surface, so it never needs to know or display one.
  Future<void> _who() async {
    final p = await SharedPreferences.getInstance();
    if (mounted) setState(() => who = p.getString('user_email'));
  }

  Future<void> _go(bool register) async {
    setState(() => busy = true);
    try {
      final u = await Api.signIn(email.text.trim(), password.text,
          register: register, name: email.text.split('@').first);
      if (!mounted) return;
      who = (u['email'] ?? '').toString();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Signed in as ${(u['email'] ?? '').toString()} — synced with the website database')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    if (mounted) setState(() => busy = false);
    await _who();
  }

  @override
  Widget build(BuildContext context) {
    if (who != null) {
      return Column(children: [
        Card(
            child: ListTile(
          leading: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                  color: mint.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.verified_user, color: mint)),
          title:
              Text(who!, style: const TextStyle(fontWeight: FontWeight.w800)),
          subtitle: const Text('Synced automatically when you comment or rate',
              style: TextStyle(color: muted, fontSize: 12)),
          trailing: TextButton(
              onPressed: () async {
                await Api.signOut();
                await _who();
              },
              child: const Text('Sign out')),
        )),
      ]);
    }
    return Card(
        child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Account (optional)',
            style: TextStyle(fontWeight: FontWeight.w800)),
        const Text('Same permanent database as the site.',
            style: TextStyle(color: muted, fontSize: 12)),
        const SizedBox(height: 10),
        TextField(
            controller: email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
                labelText: 'Email (Gmail / iCloud)',
                prefixIcon: Icon(Icons.email_outlined))),
        const SizedBox(height: 8),
        TextField(
            controller: password,
            obscureText: true,
            decoration: const InputDecoration(
                labelText: 'Password', prefixIcon: Icon(Icons.lock_outline))),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
              child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: amber, foregroundColor: Colors.black),
                  onPressed: busy ? null : () => _go(false),
                  child: Text(busy ? 'Please wait…' : 'Sign in'))),
          const SizedBox(width: 8),
          Expanded(
              child: OutlinedButton(
                  onPressed: busy ? null : () => _go(true),
                  child: const Text('Register'))),
        ]),
      ]),
    ));
  }
}

/// Pill under the action buttons showing the download quality in force.
class _DownloadQualityRow extends StatelessWidget {
  final String value;
  final VoidCallback onTap;
  const _DownloadQualityRow({required this.value, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: CamColors.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: CamColors.line),
        ),
        child: Row(children: [
          const Icon(Icons.high_quality_rounded,
              size: 17, color: CamColors.accent),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              'Download quality · ${downloadQualityLabel(value)}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
          Text('Change',
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: Theme.of(context).colorScheme.primary)),
          const Icon(Icons.chevron_right_rounded,
              size: 18, color: CamColors.inkDim),
        ]),
      ),
    );
  }
}

// ── Settings (gear screen) ─────────────────────────────

// ── Detail screen: cinematic sections ───────────────────
class _DetailHero extends StatelessWidget {
  final String title;
  final String nativeTitle;
  final String backdrop;
  final String poster;
  final String rating;
  final String year;
  final String format;
  final String status;
  final int episodes;

  const _DetailHero({
    required this.title,
    required this.nativeTitle,
    required this.backdrop,
    required this.poster,
    required this.rating,
    required this.year,
    required this.format,
    required this.status,
    required this.episodes,
  });

  @override
  Widget build(BuildContext context) {
    final hasRating = rating.isNotEmpty && rating != '0' && rating != 'null';
    return SizedBox(
      height: 324,
      child: Stack(fit: StackFit.expand, children: [
        CachedPosterImage(url: backdrop.isNotEmpty ? backdrop : poster),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [0, 0.42, 1],
              colors: [Color(0xE605060A), Color(0x3305060A), CamColors.bg],
            ),
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 14,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 94,
                height: 140,
                child: CachedPosterImage(url: poster),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (nativeTitle.isNotEmpty)
                      Text(nativeTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: CamColors.inkDim, fontSize: 11)),
                    const SizedBox(height: 4),
                    Text(title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 23,
                            height: 1.12,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.5)),
                    const SizedBox(height: 9),
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      if (hasRating) _RatingPill(rating),
                      if (year.isNotEmpty) _FactPill(year),
                      if (format.isNotEmpty) _FactPill(format),
                      if (episodes > 0) _FactPill('$episodes EP'),
                    ]),
                    if (status.isNotEmpty) ...[
                      const SizedBox(height: 7),
                      Text(status.toUpperCase(),
                          style: const TextStyle(
                              color: CamColors.accent,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.1)),
                    ],
                  ]),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _RatingPill extends StatelessWidget {
  final String rating;
  const _RatingPill(this.rating);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: CamColors.accent.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: CamColors.accent.withValues(alpha: 0.4)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.star_rounded, size: 13, color: CamColors.accent),
          const SizedBox(width: 3),
          Text(rating,
              style: const TextStyle(
                  color: CamColors.accent,
                  fontSize: 11,
                  fontWeight: FontWeight.w800)),
        ]),
      );
}

class _FactPill extends StatelessWidget {
  final String text;
  const _FactPill(this.text);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.42),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: CamColors.line),
        ),
        child: Text(text,
            style: const TextStyle(
                color: CamColors.ink,
                fontSize: 10.5,
                fontWeight: FontWeight.w700)),
      );
}

class _GenreRow extends StatelessWidget {
  final List<String> genres;
  const _GenreRow({required this.genres});

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final genre in genres.take(8))
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: CamColors.surfaceAlt,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: CamColors.line),
              ),
              child: Text(genre,
                  style: const TextStyle(
                      color: CamColors.inkDim,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600)),
            ),
        ],
      );
}

class _Synopsis extends StatefulWidget {
  final String text;
  const _Synopsis({required this.text});
  @override
  State<_Synopsis> createState() => _SynopsisState();
}

class _SynopsisState extends State<_Synopsis> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AnimatedSize(
        duration: const Duration(milliseconds: 180),
        alignment: Alignment.topCenter,
        child: Text(
          widget.text,
          maxLines: _open ? null : 3,
          overflow: _open ? TextOverflow.visible : TextOverflow.ellipsis,
          style: const TextStyle(
              color: CamColors.inkDim, fontSize: 12.5, height: 1.55),
        ),
      ),
      GestureDetector(
        onTap: () => setState(() => _open = !_open),
        child: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(_open ? 'Show less' : 'Read more',
              style: const TextStyle(
                  color: CamColors.accent,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700)),
        ),
      ),
    ]);
  }
}

class _ActionRow extends StatelessWidget {
  final String watchLabel;
  final int? myScore;
  final VoidCallback? onWatch;
  final VoidCallback? onDownload;
  final VoidCallback onRate;
  final bool saved;
  final VoidCallback onSave;

  const _ActionRow({
    required this.watchLabel,
    required this.myScore,
    required this.onWatch,
    required this.onDownload,
    required this.onRate,
    required this.saved,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
        flex: 3,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            gradient: const LinearGradient(
                colors: [Color(0xFFFFC46B), Color(0xFFFF9A3D)]),
          ),
          child: SizedBox(
            height: 46,
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.transparent,
                shadowColor: Colors.transparent,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11)),
                textStyle: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w800),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              onPressed: onWatch,
              icon: const Icon(Icons.play_arrow_rounded, size: 21),
              label: Text(watchLabel,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        flex: 2,
        child: SizedBox(
          height: 46,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              backgroundColor: CamColors.surfaceAlt,
              foregroundColor: CamColors.ink,
              side: const BorderSide(color: CamColors.line),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(11)),
              textStyle:
                  const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
              padding: const EdgeInsets.symmetric(horizontal: 6),
            ),
            onPressed: onDownload,
            icon: const Icon(Icons.download_rounded, size: 18),
            label: const Text('Download',
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      ),
      const SizedBox(width: 8),
      _RoundButton(
        icon: saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
        tooltip: saved ? 'In your watchlist' : 'Add to watchlist',
        onTap: onSave,
        size: 46,
      ),
      const SizedBox(width: 8),
      _RoundButton(
        icon: Icons.star_outline_rounded,
        tooltip: myScore == null ? 'Rate this anime' : 'Rated $myScore/10',
        onTap: onRate,
        badge: myScore?.toString(),
        size: 46,
      ),
    ]);
  }
}

class _AudioSeasonBar extends StatelessWidget {
  final String audio;
  final bool? dubAvailable;
  final ValueChanged<String> onAudio;
  final String currentId;
  final String currentTitle;
  final List seasons;
  final void Function(String id, String title) onSeason;

  const _AudioSeasonBar({
    required this.audio,
    this.dubAvailable,
    required this.onAudio,
    required this.currentId,
    required this.currentTitle,
    required this.seasons,
    required this.onSeason,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: CamColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: CamColors.line),
      ),
      child: Row(children: [
        Expanded(
          child: SegmentedButton<String>(
            segments: [
              const ButtonSegment(
                  value: 'sub',
                  icon: Icon(Icons.closed_caption_rounded, size: 14),
                  label: Text('SUB')),
              ButtonSegment(
                  value: 'dub',
                  enabled: dubAvailable != false,
                  icon: Icon(Icons.headphones_rounded, size: 14),
                  label: Text('DUB')),
            ],
            selected: {audio},
            showSelectedIcon: false,
            onSelectionChanged: (value) => onAudio(value.first),
            expandedInsets: EdgeInsets.zero,
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
              textStyle: const WidgetStatePropertyAll(TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5)),
              side: const WidgetStatePropertyAll(
                  BorderSide(color: CamColors.line)),
            ),
          ),
        ),
        if (seasons.isNotEmpty) ...[
          const SizedBox(width: 6),
          Container(width: 0.8, height: 24, color: CamColors.line),
          const SizedBox(width: 6),
          PopupMenuButton<String>(
            tooltip: 'Switch season',
            onSelected: (id) {
              Map? match;
              for (final raw in seasons) {
                if (raw is Map && '${raw['id']}' == id) match = raw;
              }
              if (match == null) return;
              onSeason(id, (match['title'] ?? 'Anime').toString());
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                  value: currentId,
                  child: Text(currentTitle,
                      maxLines: 1, overflow: TextOverflow.ellipsis)),
              for (final raw in seasons)
                if (raw is Map && '${raw['id'] ?? ''}'.isNotEmpty)
                  PopupMenuItem(
                    value: '${raw['id']}',
                    child: Text(
                        '${raw['relation'] ?? 'Related'}: ${raw['title'] ?? 'Untitled'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
            ],
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: CamColors.surfaceAlt,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: const [
                Icon(Icons.swap_horiz_rounded,
                    size: 15, color: CamColors.inkDim),
                SizedBox(width: 5),
                Text('Season',
                    style:
                        TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
                SizedBox(width: 2),
                Icon(Icons.expand_more_rounded,
                    size: 15, color: CamColors.inkDim),
              ]),
            ),
          ),
        ],
      ]),
    );
  }
}

class _SelectionBar extends StatelessWidget {
  final int count;
  final VoidCallback onPlayQueue;
  final VoidCallback onDownload;
  final VoidCallback onClear;

  const _SelectionBar({
    required this.count,
    required this.onPlayQueue,
    required this.onDownload,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 10),
      decoration: BoxDecoration(
        color: CamColors.accent.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: CamColors.accent.withValues(alpha: 0.35)),
      ),
      child: Column(children: [
        Row(children: [
          const Icon(Icons.check_circle_rounded,
              size: 15, color: CamColors.accent),
          const SizedBox(width: 6),
          Text('$count selected',
              style: const TextStyle(
                  color: CamColors.accent,
                  fontSize: 12,
                  fontWeight: FontWeight.w800)),
          const Spacer(),
          IconButton(
            tooltip: 'Clear selection',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close_rounded, size: 18),
            onPressed: onClear,
          ),
        ]),
        const SizedBox(height: 2),
        Row(children: [
          Expanded(
            child: SizedBox(
              height: 40,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: CamColors.accent,
                  foregroundColor: Colors.black,
                  textStyle: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w800),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed: onPlayQueue,
                icon: const Icon(Icons.playlist_play_rounded, size: 18),
                label: Text('Play queue ($count)',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SizedBox(
              height: 40,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: CamColors.ink,
                  side: const BorderSide(color: CamColors.line),
                  textStyle: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed: onDownload,
                icon: const Icon(Icons.download_rounded, size: 17),
                label: const Text('Download',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
          ),
        ]),
      ]),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  final String eyebrow;
  final String title;
  final Widget? trailing;
  const _SectionHeading(
      {required this.eyebrow, required this.title, this.trailing});

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(eyebrow.toUpperCase(),
                  style: const TextStyle(
                      color: CamColors.inkDim,
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2)),
              const SizedBox(height: 3),
              Text(title,
                  style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2)),
            ]),
          ),
          if (trailing != null) trailing!,
        ],
      );
}

class _SeasonsRail extends StatelessWidget {
  final List seasons;
  final void Function(String id, String title) onOpen;
  const _SeasonsRail({required this.seasons, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: seasons.length,
      separatorBuilder: (_, __) => const SizedBox(width: 10),
      itemBuilder: (_, i) {
        final raw = seasons[i];
        final s = raw is Map ? raw : const {};
        final id = '${s['id'] ?? ''}';
        return InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap:
              id.isEmpty ? null : () => onOpen(id, '${s['title'] ?? 'Anime'}'),
          child: SizedBox(
            width: 108,
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: SizedBox(
                  width: 108,
                  height: 150,
                  child: CachedPosterImage(url: '${s['image'] ?? ''}'),
                ),
              ),
              const SizedBox(height: 6),
              Text((s['relation'] ?? 'Related').toString().toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: CamColors.accent,
                      fontSize: 8.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6)),
              const SizedBox(height: 2),
              Text('${s['title'] ?? 'Untitled'}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      height: 1.25)),
              const SizedBox(height: 2),
              Text('${s['episode_count'] ?? '?'} EP · ${s['year'] ?? '—'}',
                  style:
                      const TextStyle(color: CamColors.inkDim, fontSize: 9.5)),
            ]),
          ),
        );
      },
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final String? badge;
  final double size;

  const _RoundButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.badge,
    this.size = 38,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black.withValues(alpha: 0.5),
        shape: CircleBorder(side: BorderSide(color: CamColors.line)),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Stack(alignment: Alignment.center, children: [
            SizedBox(
              width: size,
              height: size,
              child: Icon(icon, size: size * 0.48, color: CamColors.ink),
            ),
            if (badge != null)
              Positioned(
                right: 5,
                top: 5,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: CamColors.accent,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(badge!,
                      style: const TextStyle(
                          color: Colors.black,
                          fontSize: 8,
                          fontWeight: FontWeight.w900)),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}
