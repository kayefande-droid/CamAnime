import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/ad_notifications.dart';
import '../core/app_notifications.dart';
import '../core/cam_ui.dart';
import '../core/downloads.dart';
import '../core/models.dart';

/// Real, functional settings — every switch here changes app behaviour.
class SettingsScreen extends StatefulWidget {
  final String themeName;
  final ValueChanged<String> onTheme;
  final VoidCallback onCheckUpdate;
  final VoidCallback? onReplayTour;
  final String version;
  final String credit;
  final Map<String, Map<String, dynamic>> themes;

  const SettingsScreen({
    super.key,
    required this.themeName,
    required this.onTheme,
    required this.onCheckUpdate,
    this.onReplayTour,
    this.version = '',
    this.credit = '',
    this.themes = const {},
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

/// Notification bell + inbox: shows unread count badge and the list of
/// announcements published by the CamAnime team.
class NotificationBellScreen extends StatefulWidget {
  const NotificationBellScreen({super.key});

  @override
  State<NotificationBellScreen> createState() => _NotificationBellScreenState();
}

class _NotificationBellScreenState extends State<NotificationBellScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await http
          .get(Uri.parse('$apiHost/api/announcements'))
          .timeout(const Duration(seconds: 12));
      final data = json.decode(r.body) as Map<String, dynamic>;
      final list = (data['announcements'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          TextButton(
              onPressed: _loading ? null : _load,
              child: const Text('Refresh')),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline,
                          size: 48, color: CamColors.inkDim),
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(color: CamColors.inkDim)),
                      const SizedBox(height: 12),
                      FilledButton(
                          onPressed: _load,
                          child: const Text('Retry')),
                    ],
                  ),
                )
              : _items.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.notifications_none_outlined,
                              size: 56, color: CamColors.inkDim),
                          SizedBox(height: 12),
                          Text('No notifications yet',
                              style: TextStyle(color: CamColors.inkDim)),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _items.length,
                        itemBuilder: (context, index) {
                          final item = _items[index];
                          final title = item['title']?.toString() ?? 'CamAnime';
                          final body = item['body']?.toString() ?? '';
                          final ts = item['t'] as int? ?? 0;
                          final dt = ts > 0
                              ? DateTime.fromMillisecondsSinceEpoch(ts * 1000)
                              : null;
                          return InkWell(
                            onTap: () {
                              // Open the app to the relevant place; for now open home.
                              // The tap is a no-op if the message was already seen.
                            },
                            child: Card(
                              margin: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 4),
                              child: Padding(
                                padding: const EdgeInsets.all(14),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Icon(Icons.notifications_active,
                                            size: 18, color: accent),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(title,
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.w800,
                                                  fontSize: 14)),
                                        ),
                                        if (dt != null)
                                          Text(_rel(dt),
                                              style: const TextStyle(
                                                  color: CamColors.inkDim,
                                                  fontSize: 11)),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Text(body,
                                        style: const TextStyle(
                                            color: CamColors.inkDim,
                                            fontSize: 12.5,
                                            height: 1.4)),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
    );
  }

  String _rel(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    return '${diff.inDays}d ago';
  }  }


class _SettingsScreenState extends State<SettingsScreen> {
  final _manager = DownloadManager.instance;
  String audio = 'sub';
  bool autoplay = true;
  bool resume = true;
  bool dataSaver = false;
  int concurrency = 2;
  String quality = '720';
  String streamQuality = 'auto';
  bool saveToDevice = true;
  bool adverts = true;
  String email = '';
  bool downloadAlerts = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final p = await SharedPreferences.getInstance();
    await _manager.init();
    if (!mounted) return;
    setState(() {
      audio = (p.getString('app_audio') ?? 'sub') == 'dub' ? 'dub' : 'sub';
      autoplay = p.getBool('app_autoplay') ?? true;
      resume = p.getBool('app_resume') ?? true;
      dataSaver = p.getBool('app_data_saver') ?? false;
      concurrency = _manager.concurrency;
      final savedQuality = p.getString('download_quality') ?? '720';
      quality = const {'ask', 'smallest', 'best', '360', '480', '720', '1080'}
              .contains(savedQuality)
          ? savedQuality
          : '720';
      final savedStream = p.getString('stream_quality') ?? 'auto';
      streamQuality =
          kStreamQualities.contains(savedStream) ? savedStream : 'auto';
      saveToDevice = p.getBool('save_to_device') ?? true;
      adverts = p.getBool(AdNotifications.prefKey) ?? true;
      email = p.getString('user_email') ?? '';
      downloadAlerts = p.getBool(AppNotifications.prefKey) ?? true;
    });
  }

  Future<void> _setBool(String key, bool value) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(key, value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: AnimatedBuilder(
        animation: _manager,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 36),
          children: [
            _group('Recommended', [
              _tile(
                icon: Icons.auto_awesome_rounded,
                title: 'Apply recommended settings',
                subtitle:
                    'Small downloads, data-saver streaming, autoplay and alerts',
                trailing: const Icon(Icons.chevron_right_rounded,
                    color: CamColors.inkDim),
                onTap: _applyRecommended,
              ),
              const Divider(height: 1),
              _tile(
                icon: Icons.tune_rounded,
                title: 'Recommended at a glance',
                subtitle: 'English subtitles (SUB) \u00b7 smallest published download \u00b7 '
                    'data-saver streaming \u00b7 save to device \u00b7 autoplay on',
              ),
            ]),
            _group('Appearance', [
              Padding(
                padding: const EdgeInsets.all(14),
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final entry in widget.themes.entries)
                    ChoiceChip(
                      label:
                          Text((entry.value['label'] ?? entry.key).toString()),
                      selected: widget.themeName == entry.key,
                      avatar: CircleAvatar(
                        radius: 8,
                        backgroundColor:
                            Color((entry.value['seed'] as int?) ?? 0xFF087BFF),
                      ),
                      onSelected: (_) => widget.onTheme(entry.key),
                    ),
                ]),
              ),
            ]),
            _group('Playback', [
              _tile(
                icon: Icons.translate_rounded,
                title: 'Default audio',
                subtitle: 'English dub (DUB) plays only where the provider publishes it; '
                    'otherwise English subtitles (SUB) are used',
                trailing: SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'sub', label: Text('English SUB')),
                    ButtonSegment(value: 'dub', label: Text('English DUB')),
                  ],
                  selected: {audio},
                  onSelectionChanged: (value) async {
                    setState(() => audio = value.first);
                    final p = await SharedPreferences.getInstance();
                    await p.setString('app_audio', value.first);
                  },
                ),
              ),
              _switchTile(
                icon: Icons.skip_next_rounded,
                title: 'Autoplay next episode',
                subtitle: 'Start the next episode when this one ends',
                value: autoplay,
                onChanged: (v) async {
                  setState(() => autoplay = v);
                  await _setBool('app_autoplay', v);
                },
              ),
              _tile(
                icon: Icons.high_quality_rounded,
                title: 'Streaming quality',
                subtitle: streamQuality == 'auto'
                    ? 'Plays the source as published · HLS adapts within the '
                        'provider\u2019s real renditions'
                    : '${streamQualityLabel(streamQuality)} · never upscales',
                trailing: DropdownButton<String>(
                  value: streamQuality,
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(value: 'auto', child: Text('Auto')),
                    DropdownMenuItem(
                        value: '1080', child: Text('Prefer 1080p')),
                    DropdownMenuItem(value: '720', child: Text('Prefer 720p')),
                    DropdownMenuItem(value: '480', child: Text('Prefer 480p')),
                    DropdownMenuItem(value: '360', child: Text('Prefer 360p')),
                  ],
                  onChanged: (value) async {
                    if (value == null) return;
                    setState(() => streamQuality = value);
                    final p = await SharedPreferences.getInstance();
                    await p.setString('stream_quality', value);
                  },
                ),
              ),
              _switchTile(
                icon: Icons.restore_rounded,
                title: 'Resume playback',
                subtitle: 'Continue each episode where you left it',
                value: resume,
                onChanged: (v) async {
                  setState(() => resume = v);
                  await _setBool('app_resume', v);
                },
              ),
              _switchTile(
                icon: Icons.data_saver_on_rounded,
                title: 'Data saver',
                subtitle:
                    'Skip prefetching next-episode sources and extra requests',
                value: dataSaver,
                onChanged: (v) async {
                  setState(() => dataSaver = v);
                  await _setBool('app_data_saver', v);
                },
              ),
            ]),
            _group('Downloads', [
              _tile(
                icon: Icons.straighten_rounded,
                title: 'Download & stream by pixel size',
                subtitle: 'Download ${_qualityLabel(quality)} \u00b7 '
                    'stream ${_qualityLabel(streamQuality)}',
                trailing: const Icon(Icons.chevron_right_rounded,
                    color: CamColors.inkDim),
                onTap: _pixelPanel,
              ),
              _switchTile(
                icon: Icons.smartphone_rounded,
                title: 'Save to device storage',
                subtitle: Platform.isAndroid
                    ? 'Copy finished episodes to Download/CamAnime, grouped by anime and season'
                    : 'Available on Android',
                value: saveToDevice,
                onChanged: (v) async {
                  setState(() => saveToDevice = v);
                  await _setBool('save_to_device', v);
                },
              ),
              _switchTile(
                icon: Icons.sync_rounded,
                title: 'Auto-resume downloads',
                subtitle:
                    'Keep retrying with Range requests until internet returns',
                value: _manager.autoResume,
                onChanged: (v) => _manager.setAutoResume(v),
              ),
              _tile(
                icon: Icons.high_quality_rounded,
                title: 'Download resolution',
                subtitle: quality == 'ask'
                    ? 'Pick the exact file and size before every download'
                    : quality == 'smallest'
                        ? 'Smallest file offered — fastest and least storage'
                        : quality == 'best'
                            ? 'Highest resolution offered — largest files'
                            : '${downloadQualityLabel(quality)} · only '
                                'provider-published files',
                trailing: DropdownButton<String>(
                  value: quality,
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(value: '1080', child: Text('Up to 1080p')),
                    DropdownMenuItem(value: '720', child: Text('Up to 720p')),
                    DropdownMenuItem(value: '480', child: Text('Up to 480p')),
                    DropdownMenuItem(value: '360', child: Text('Up to 360p')),
                    DropdownMenuItem(
                        value: 'smallest', child: Text('Smallest')),
                    DropdownMenuItem(value: 'best', child: Text('Best')),
                    DropdownMenuItem(value: 'ask', child: Text('Ask')),
                  ],
                  onChanged: (value) async {
                    if (value == null) return;
                    setState(() => quality = value);
                    final p = await SharedPreferences.getInstance();
                    await p.setString('download_quality', value);
                  },
                ),
              ),
              const Divider(height: 1),
              _tile(
                icon: Icons.history_toggle_off_rounded,
                title: 'Clear watch history',
                subtitle: 'Forget every resume position on this device',
                trailing: const Icon(Icons.chevron_right_rounded,
                    color: CamColors.inkDim),
                onTap: _clearWatchHistory,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: Row(children: [
                  const Icon(Icons.speed_rounded,
                      size: 20, color: CamColors.inkDim),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Simultaneous downloads',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                          SizedBox(height: 2),
                          Text('Lower values are kinder to slow connections',
                              style: TextStyle(
                                  color: CamColors.inkDim, fontSize: 11)),
                        ]),
                  ),
                  SegmentedButton<int>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 1, label: Text('1')),
                      ButtonSegment(value: 2, label: Text('2')),
                      ButtonSegment(value: 3, label: Text('3')),
                    ],
                    selected: {_manager.concurrency},
                    onSelectionChanged: (value) =>
                        _manager.setConcurrency(value.first),
                  ),
                ]),
              ),
              const Divider(height: 1),
              _tile(
                icon: Icons.sd_storage_rounded,
                title: 'Storage used',
                subtitle:
                    '${_manager.readyCount} episodes · ${compactBytes(_manager.bytesUsed)}',
                trailing: Text(
                  compactBytes(_manager.bytesUsed),
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, color: CamColors.success),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
                child: Row(children: [
                  Expanded(
                    child: CamGhostButton(
                      label: 'Resume all',
                      icon: Icons.play_circle_outline_rounded,
                      onPressed:
                          _manager.active.isEmpty ? null : _manager.resumeAll,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: CamGhostButton(
                      label: 'Clear offline',
                      icon: Icons.delete_sweep_outlined,
                      onPressed: _manager.readyCount == 0
                          ? null
                          : () => _confirmClear(),
                    ),
                  ),
                ]),
              ),
            ]),
            if (Platform.isAndroid)
              _group('Notifications', [
                _switchTile(
                  icon: Icons.notifications_active_outlined,
                  title: 'Anime advert notifications',
                  subtitle: adverts
                      ? 'Two anime suggestions every hour · turn off anytime'
                      : 'Off — no advert notifications',
                  value: adverts,
                  onChanged: (v) async {
                    setState(() => adverts = v);
                    await AdNotifications.setEnabled(v);
                  },
                ),
                const Divider(height: 1),
                _switchTile(
                  icon: Icons.download_done_rounded,
                  title: 'Download finished alerts',
                  subtitle:
                      'A heads-up notification when an episode is ready offline',
                  value: downloadAlerts,
                  onChanged: (v) async {
                    setState(() => downloadAlerts = v);
                    await AppNotifications.setEnabled(v);
                  },
                ),
              ]),
            _group('Profile', [
              _tile(
                icon: Icons.account_circle_outlined,
                title: 'View profile picture',
                subtitle: 'See your avatar enlarged',
                trailing: const Icon(Icons.chevron_right_rounded,
                    color: CamColors.inkDim),
                onTap: _viewProfilePicture,
              ),
            ]),
            _group('Account', [
              _tile(
                icon: Icons.person_outline_rounded,
                title: email.isEmpty ? 'Guest' : email,
                subtitle: email.isEmpty
                    ? 'No account needed to watch or download'
                    : 'Signed in to CamAnime',
                trailing: const Icon(Icons.chevron_right_rounded,
                    color: CamColors.inkDim),
                onTap: () => Navigator.pop(context),
              ),
            ]),
            _group('Watch history', [
              _tile(
                icon: Icons.history_rounded,
                title: 'Clear watch history',
                subtitle: 'Removes every saved resume point on this device',
                trailing: const Icon(Icons.delete_outline_rounded,
                    color: CamColors.inkDim),
                onTap: _clearHistory,
              ),
            ]),
            _group('Websites', [
              _tile(
                icon: Icons.public_rounded,
                title: 'CamAnime on Render',
                subtitle: 'Primary site · catalogue, downloads, developer API',
                trailing: const Icon(Icons.open_in_new_rounded,
                    color: CamColors.inkDim, size: 18),
                onTap: () => _openSite('https://camanime.onrender.com'),
              ),
              const Divider(height: 1),
              _tile(
                icon: Icons.cloud_rounded,
                title: 'CamAnime on Cloudflare',
                subtitle: 'Mirror site · same catalogue and API',
                trailing: const Icon(Icons.open_in_new_rounded,
                    color: CamColors.inkDim, size: 18),
                onTap: () => _openSite('https://camanjme.camanime.workers.dev'),
              ),
            ]),
            _group('About', [
              _tile(
                icon: Icons.info_rounded,
                title: 'About CamAnime',
                subtitle: 'Version, build and credits',
                trailing: const Icon(Icons.chevron_right_rounded,
                    color: CamColors.inkDim),
                onTap: _aboutDialog,
              ),
              _tile(
                icon: Icons.info_outline_rounded,
                title: widget.version.isEmpty
                    ? 'CamAnime'
                    : 'CamAnime ${widget.version}',
                subtitle: widget.credit,
              ),
              _tile(
                icon: Icons.cloud_outlined,
                title: 'Website',
                subtitle: apiHost,
              ),
              _tile(
                icon: Icons.tour_outlined,
                title: 'Replay app tour',
                trailing: const Icon(Icons.chevron_right_rounded,
                    color: CamColors.inkDim),
                onTap: () {
                  widget.onReplayTour?.call();
                  Navigator.pop(context);
                },
              ),
              _tile(
                icon: Icons.system_update_rounded,
                title: 'Check for updates',
                subtitle: 'Builds are published on the CamAnime website',
                trailing: const Icon(Icons.chevron_right_rounded,
                    color: CamColors.inkDim),
                onTap: widget.onCheckUpdate,
              ),
              _tile(
                icon: Icons.notifications_outlined,
                title: 'Notifications',
                subtitle: 'Announcements from the CamAnime team',
                trailing: const Icon(Icons.chevron_right_rounded,
                    color: CamColors.inkDim),
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const NotificationBellScreen())),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  String _qualityLabel(String value) {
    switch (value) {
      case 'smallest':
        return 'smallest file';
      case 'best':
        return 'best quality';
      case 'auto':
        return 'auto';
      case 'ask':
        return 'ask each time';
      default:
        return 'Up to ${value}p';
    }
  }

  /// One tap puts every choice back to what works best on a phone: English subtitles (SUB),
  /// 480p downloads to keep files small, data-saver streaming, autoplay on,
  /// saved copies in device storage, and the download-complete alert on.
  Future<void> _applyRecommended() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('app_audio', 'sub');
    await p.setString('download_quality', '480');
    await p.setString('stream_quality', '480');
    await p.setBool('app_autoplay', true);
    await p.setBool('app_resume', true);
    await p.setBool('app_data_saver', true);
    await p.setBool('save_to_device', true);
    await AppNotifications.setEnabled(true);
    if (!mounted) return;
    setState(() {
      audio = 'sub';
      quality = '480';
      streamQuality = '480';
      autoplay = true;
      resume = true;
      dataSaver = true;
      saveToDevice = true;
      downloadAlerts = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Recommended settings applied.')));
  }

  /// Pixel-level moderation: the exact height used for downloads and streams,
  /// so an episode can be kept small (360/480p) or sharp (720/1080p), plus the
  /// data-saver switch that caps streaming when a connection is metered.
  Future<void> _pixelPanel() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: CamColors.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        Future<void> save(String key, String value) async {
          final p = await SharedPreferences.getInstance();
          await p.setString(key, value);
          if (!mounted) return;
          setState(() {
            if (key == 'download_quality') {
              quality = value;
            } else {
              streamQuality = value;
            }
          });
          setSheet(() {});
        }

        Widget chips(List<String> values, String selected,
                ValueChanged<String> onPick) =>
            Wrap(spacing: 7, runSpacing: 7, children: [
              for (final value in values)
                ChoiceChip(
                  label: Text(_qualityLabel(value)),
                  selected: selected == value,
                  onSelected: (_) => onPick(value),
                ),
            ]);

        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 2, 20, 28),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Download & stream by pixel size',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                const Text(
                    'These are caps, not promises: CamAnime uses the highest '
                    'quality the source actually publishes at or below your '
                    'pick. Nothing is re-encoded or relabelled, so a source '
                    'that only offers 1080p downloads will keep 1080p instead '
                    'of faking a smaller file.',
                    style: TextStyle(
                        color: CamColors.inkDim, fontSize: 11.5, height: 1.4)),
                const SizedBox(height: 16),
                const Text('DOWNLOAD HEIGHT',
                    style: TextStyle(
                        color: CamColors.inkDim,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2)),
                const SizedBox(height: 6),
                chips(const ['smallest', '360', '480', '720', '1080'], quality,
                    (value) => save('download_quality', value)),
                const SizedBox(height: 16),
                const Text('STREAM HEIGHT',
                    style: TextStyle(
                        color: CamColors.inkDim,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2)),
                const SizedBox(height: 6),
                chips(const ['auto', '360', '480', '720', '1080'],
                    streamQuality, (value) => save('stream_quality', value)),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: dataSaver,
                  title: const Text('Data saver for streaming',
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  subtitle: const Text(
                      'Prefers the smallest published rendition on mobile data '
                      'so episodes cost less internet',
                      style:
                          TextStyle(color: CamColors.inkDim, fontSize: 11.5)),
                  onChanged: (v) async {
                    setState(() => dataSaver = v);
                    final p = await SharedPreferences.getInstance();
                    await p.setBool('app_data_saver', v);
                    setSheet(() {});
                  },
                ),
              ]),
        );
      }),
    );
  }

  Future<void> _clearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: CamColors.surface,
        title: const Text('Clear watch history?'),
        content: const Text(
            'Every saved resume point and Continue watching entry is removed '
            'from this device. Downloads and settings stay as they are.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: CamColors.danger,
                foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await WatchProgress.clearAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Watch history cleared.')));
  }

  Future<void> _openSite(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(url)));
    }
  }

  void _aboutDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: CamColors.surface,
        title: const Text('About CamAnime'),
        content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  'Version ${widget.version.isEmpty ? '2.9.0' : widget.version}',
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              const Text(
                  'Free anime streaming: stream, download for offline, keep '
                  'watching on any device. Built by kayefande & Co.',
                  style: TextStyle(
                      color: CamColors.inkDim, fontSize: 12, height: 1.45)),
              const SizedBox(height: 12),
              const Text('camanime.onrender.com',
                  style: TextStyle(fontSize: 11.5)),
              const Text('camanjme.camanime.workers.dev',
                  style: TextStyle(fontSize: 11.5)),
              const SizedBox(height: 10),
              Text(widget.credit,
                  style:
                      const TextStyle(color: CamColors.inkDim, fontSize: 10.5)),
            ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  Future<void> _viewProfilePicture() async {
    final p = await SharedPreferences.getInstance();
    final name = (p.getString('username') ?? '').trim();
    final idx = p.getInt('avatar_idx') ?? 0;
    final avatars = <IconData>[
      Icons.person_rounded,
      Icons.auto_awesome_rounded,
      Icons.rocket_launch_rounded,
      Icons.sports_esports_rounded,
      Icons.local_fire_department_rounded,
      Icons.nightlight_round,
    ];
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: CamColors.surface,
        title: const Text('Profile picture'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 128,
            height: 128,
            decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                    colors: [CamColors.accent, CamColors.accentAlt])),
            child: Icon(
              avatars[idx % avatars.length],
              size: 64,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 14),
          Text(name.isEmpty ? 'Guest' : name,
              style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text('Change it from your Profile tab.',
              style: TextStyle(color: CamColors.inkDim, fontSize: 11.5)),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  Widget _group(String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(top: 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              title.toUpperCase(),
              style: const TextStyle(
                  color: CamColors.inkDim,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.3),
            ),
          ),
          CamCard(
            padding: EdgeInsets.zero,
            child: Column(children: children),
          ),
        ]),
      );

  Widget _tile({
    required IconData icon,
    required String title,
    String? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(CamRadius.lg),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
          child: Row(children: [
            Icon(icon, size: 20, color: CamColors.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 13)),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(subtitle,
                            style: const TextStyle(
                                color: CamColors.inkDim, fontSize: 11)),
                      ),
                  ]),
            ),
            if (trailing != null) trailing,
          ]),
        ),
      );

  Widget _switchTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) =>
      InkWell(
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          child: Row(children: [
            Icon(icon, size: 20, color: CamColors.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 13)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: const TextStyle(
                            color: CamColors.inkDim, fontSize: 11)),
                  ]),
            ),
            Switch(value: value, onChanged: onChanged),
          ]),
        ),
      );

  Future<void> _clearWatchHistory() async {
    await WatchProgress.clearAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Watch history cleared.')));
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: CamColors.surface,
        title: const Text('Delete all offline episodes?'),
        content: const Text(
            'Every downloaded episode is removed from this device. Streaming stays available.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: CamColors.danger,
                foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete all'),
          ),
        ],
      ),
    );
    if (ok == true) await _manager.clearCompleted();
  }
}
