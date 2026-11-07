import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

class _SettingsScreenState extends State<SettingsScreen> {
  final _manager = DownloadManager.instance;
  String audio = 'sub';
  bool autoplay = false;
  bool resume = true;
  bool dataSaver = false;
  int concurrency = 2;
  String quality = '720';
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
      autoplay = p.getBool('app_autoplay') ?? false;
      resume = p.getBool('app_resume') ?? true;
      dataSaver = p.getBool('app_data_saver') ?? false;
      concurrency = _manager.concurrency;
      final savedQuality = p.getString('download_quality') ?? '720';
      quality = const {'ask', 'smallest', 'best', '360', '480', '720', '1080'}
              .contains(savedQuality)
          ? savedQuality
          : '720';
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
                subtitle: 'Used for streaming and new downloads',
                trailing: SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'sub', label: Text('SUB')),
                    ButtonSegment(value: 'dub', label: Text('DUB')),
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
                            : '${downloadQualityLabel(quality)} · never exceeds ${quality}p',
                trailing: DropdownButton<String>(
                  value: quality,
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(
                        value: '1080', child: Text('1080p')),
                    DropdownMenuItem(value: '720', child: Text('720p')),
                    DropdownMenuItem(value: '480', child: Text('480p')),
                    DropdownMenuItem(value: '360', child: Text('360p')),
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
            _group('About', [
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
            ]),
          ],
        ),
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
