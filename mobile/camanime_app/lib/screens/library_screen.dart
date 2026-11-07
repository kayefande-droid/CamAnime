import 'dart:io';

import 'package:flutter/material.dart';

import '../core/cam_ui.dart';
import '../core/downloads.dart';
import 'player_screen.dart';

/// Library = live download queue + offline episodes. A download appears here
/// the instant it is queued, and becomes playable as soon as the first
/// megabyte is on disk.
class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key});
  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  final _manager = DownloadManager.instance;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    await _manager.init();
    if (mounted) setState(() => _started = true);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: AnimatedBuilder(
        animation: _manager,
        builder: (context, _) {
          final active = [..._manager.active, ..._manager.paused];
          final ready = _manager.completed;
          return RefreshIndicator(
            color: CamColors.accent,
            backgroundColor: CamColors.surface,
            onRefresh: () async {
              await _manager.refresh();
              await _manager.kick();
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 112),
              children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('My Library',
                              style: TextStyle(
                                  fontSize: 26,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -0.6)),
                          SizedBox(height: 3),
                          Text('Downloads and offline episodes',
                              style: TextStyle(
                                  color: CamColors.inkDim, fontSize: 12.5)),
                        ]),
                  ),
                  IconButton(
                    tooltip: 'Resume all downloads',
                    onPressed: active.isEmpty ? null : _manager.resumeAll,
                    icon: const Icon(Icons.play_circle_outline_rounded),
                  ),
                ]),
                const SizedBox(height: 14),
                _summary(active.length, ready.length),
                if (!_started)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else ...[
                  const CamSectionTitle('Downloading',
                      eyebrow: 'Live queue',
                      padding: EdgeInsets.fromLTRB(0, 24, 0, 10)),
                  if (active.isEmpty)
                    CamCard(
                      padding: const EdgeInsets.all(16),
                      child: Row(children: const [
                        Icon(Icons.download_done_rounded,
                            color: CamColors.success, size: 20),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'No downloads in progress. Pick any episode and tap download — it shows up here immediately.',
                            style: TextStyle(
                                color: CamColors.inkDim,
                                fontSize: 12,
                                height: 1.4),
                          ),
                        ),
                      ]),
                    )
                  else
                    for (final task in active)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 9),
                        child: _taskTile(task),
                      ),
                  CamSectionTitle('Ready offline',
                      eyebrow: '${ready.length} episodes',
                      padding: const EdgeInsets.fromLTRB(0, 24, 0, 10)),
                  if (ready.isEmpty)
                    const CamCard(
                      child: EmptyState(
                        icon: Icons.video_library_outlined,
                        title: 'Nothing saved yet',
                        message:
                            'Downloaded episodes live here and play with no internet at all.',
                      ),
                    )
                  else
                    for (final task in ready)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 9),
                        child: _readyTile(task),
                      ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _summary(int activeCount, int readyCount) {
    final used = compactBytes(_manager.bytesUsed);
    final speed = _manager.speedBytesPerSecond;
    return CamCard(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF1B1A2B), Color(0xFF11131C)],
      ),
      padding: const EdgeInsets.all(16),
      child: Row(children: [
        Expanded(
          child: _stat('$readyCount', 'Episodes offline', CamColors.success,
              Icons.offline_pin_rounded),
        ),
        Container(width: 1, height: 40, color: CamColors.line),
        Expanded(
          child: _stat('$activeCount', 'Active', CamColors.accent,
              Icons.downloading_rounded),
        ),
        Container(width: 1, height: 40, color: CamColors.line),
        Expanded(
          child: _stat(
            speed > 0 && activeCount > 0
                ? '${compactBytes(speed.round())}/s'
                : used,
            speed > 0 && activeCount > 0 ? 'Speed' : 'On device',
            CamColors.info,
            Icons.sd_storage_rounded,
          ),
        ),
      ]),
    );
  }

  Widget _stat(String value, String label, Color color, IconData icon) =>
      Column(children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(height: 6),
        Text(value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
        const SizedBox(height: 2),
        Text(label,
            style: const TextStyle(
                color: CamColors.inkDim, fontSize: 10, height: 1.2)),
      ]);

  Widget _taskTile(DownloadTask task) {
    final playable = _manager.playableFile(task);
    final partial = _manager.isPartial(task);
    final progress = task.progress;
    return CamCard(
      padding: const EdgeInsets.all(13),
      child: Column(children: [
        Row(children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: CamColors.surfaceAlt,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: CamColors.line),
            ),
            child: Text('${task.episode}',
                style:
                    const TextStyle(fontWeight: FontWeight.w900, fontSize: 14)),
          ),
          const SizedBox(width: 11),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(task.animeTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 13)),
              const SizedBox(height: 3),
              Text(
                'Episode ${task.episode} · ${task.audio.toUpperCase()} · '
                '${task.stage.label}',
                style: TextStyle(
                    color: task.stage == DownloadStage.waitingNetwork
                        ? CamColors.accent
                        : CamColors.inkDim,
                    fontSize: 11),
              ),
            ]),
          ),
          if (task.stage == DownloadStage.downloading)
            IconButton(
              tooltip: 'Pause',
              onPressed: () => _manager.pause(task.id),
              icon: const Icon(Icons.pause_circle_outline_rounded,
                  color: CamColors.inkDim, size: 22),
            )
          else if (task.stage == DownloadStage.paused ||
              task.stage == DownloadStage.failed)
            IconButton(
              tooltip: 'Resume',
              onPressed: () => _manager.resume(task.id),
              icon: const Icon(Icons.play_circle_outline_rounded,
                  color: CamColors.success, size: 22),
            )
          else
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          IconButton(
            tooltip: 'Remove download',
            onPressed: () => _confirmRemove(task),
            icon: const Icon(Icons.close_rounded,
                color: CamColors.inkDim, size: 19),
          ),
        ]),
        const SizedBox(height: 9),
        CamProgress(
          value: progress,
          color: task.stage == DownloadStage.waitingNetwork
              ? CamColors.accent
              : CamColors.success,
        ),
        const SizedBox(height: 6),
        Row(children: [
          Text(
            progress == null
                ? compactBytes(task.received)
                : '${compactBytes(task.received)} of ${compactBytes(task.total)}'
                    ' · ${(progress * 100).round()}%',
            style: const TextStyle(color: CamColors.inkDim, fontSize: 10.5),
          ),
          const Spacer(),
          if (playable != null && partial)
            TextButton.icon(
              onPressed: () => _playFile(playable, task),
              icon: const Icon(Icons.play_arrow_rounded, size: 16),
              label: const Text('Watch downloaded part'),
            ),
        ]),
        if (task.error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(task.error,
                  style:
                      const TextStyle(color: CamColors.accent, fontSize: 10.5)),
            ),
          ),
      ]),
    );
  }

  Widget _readyTile(DownloadTask task) {
    final file = _manager.playableFile(task);
    return CamCard(
      padding: const EdgeInsets.all(12),
      onTap: file == null ? null : () => _playFile(file, task),
      child: Row(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: 46,
            height: 46,
            child: task.image.isEmpty
                ? Container(
                    color: CamColors.surfaceAlt,
                    alignment: Alignment.center,
                    child: Text('${task.episode}',
                        style: const TextStyle(
                            fontWeight: FontWeight.w900, fontSize: 15)),
                  )
                : Image.network(
                    task.image,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      color: CamColors.surfaceAlt,
                      alignment: Alignment.center,
                      child: Text('${task.episode}',
                          style: const TextStyle(fontWeight: FontWeight.w900)),
                    ),
                  ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(task.animeTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
            const SizedBox(height: 3),
            Text(
              'Ep ${task.episode} · ${task.audio.toUpperCase()} · '
              '${compactBytes(task.total)}',
              style: const TextStyle(color: CamColors.inkDim, fontSize: 10.5),
            ),
          ]),
        ),
        if (file != null)
          IconButton(
            tooltip: 'Play offline',
            onPressed: () => _playFile(file, task),
            icon: const Icon(Icons.play_circle_fill_rounded,
                color: CamColors.success, size: 30),
          ),
        IconButton(
          tooltip: 'Delete',
          onPressed: () => _confirmRemove(task),
          icon: const Icon(Icons.delete_outline_rounded,
              color: CamColors.inkDim, size: 20),
        ),
      ]),
    );
  }

  void _playFile(File file, DownloadTask task) {
    final partial = file.path.endsWith('.part');
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          url: file.path,
          label: '${task.displayTitle}${partial ? ' (downloading)' : ''}',
          localFile: true,
          onOpenAnime: (id, title) => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => _AnimeOpener(animeId: id, title: title)),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmRemove(DownloadTask task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: CamColors.surface,
        title: const Text('Remove download?'),
        content: Text(
            '${task.displayTitle} will be deleted from this device. You can download it again any time.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: CamColors.danger,
                foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _manager.remove(task.id);
  }
}

/// Small shim so Library can jump to a detail page without importing the
/// monolithic main file; the app-level navigator resolves the route.
class _AnimeOpener extends StatelessWidget {
  final String animeId;
  final String title;
  const _AnimeOpener({required this.animeId, required this.title});

  @override
  Widget build(BuildContext context) =>
      AnimeDetailLauncher(animeId: animeId, title: title);
}

/// Overridden at runtime by `main.dart` to avoid a circular import.
class AnimeDetailLauncher extends StatelessWidget {
  static Widget Function(String animeId, String title)? builder;
  final String animeId;
  final String title;
  const AnimeDetailLauncher(
      {super.key, required this.animeId, required this.title});

  @override
  Widget build(BuildContext context) {
    final make = builder;
    if (make == null) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: const Center(child: Text('Open this anime from Home.')),
      );
    }
    return make(animeId, title);
  }
}
