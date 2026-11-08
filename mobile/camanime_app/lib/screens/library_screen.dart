import 'dart:io';

import 'package:flutter/material.dart';

import '../core/cam_ui.dart';
import '../core/device_storage.dart';
import '../core/downloads.dart';
import '../core/models.dart';
import '../core/watchlist.dart';
import '../main.dart' show DetailScreen;
import 'player_screen.dart';

/// Library = live download queue + offline episodes, folded into one folder
/// per anime season so a long series never buries the rest of the shelf.
class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key});
  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  final _manager = DownloadManager.instance;
  bool _started = false;
  final Set<String> _expanded = {};

  /// Where each downloaded series was left off: folder key -> episode + ms.
  Map<String, Map<String, dynamic>> _resume = const {};

  /// 0 = downloads, 1 = watchlist, 2 = history.
  int _view = 0;
  List<Map<String, dynamic>> _watch = const [];
  List<Map<String, dynamic>> _history = const [];

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    await _manager.init();
    if (!mounted) return;
    setState(() => _started = true);
    await _loadResume();
    await _loadLists();
  }

  Future<void> _loadLists() async {
    final watch = await Watchlist.entries();
    final history = await WatchProgress.history();
    if (!mounted) return;
    setState(() {
      _watch = watch;
      _history = history;
    });
  }

  Future<void> _openAnime(String id, String title) async {
    if (id.trim().isEmpty || id.startsWith('title:')) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DetailScreen(animeId: id, title: title),
    ));
    await _loadLists();
  }

  /// Reads the saved position for every anime in the library, so a folder can
  /// offer "Continue ep 7" instead of making the user remember.
  Future<void> _loadResume() async {
    final next = <String, Map<String, dynamic>>{};
    for (final folder in _manager.folders) {
      String id = '';
      for (final task in folder.tasks) {
        final candidate = '${task.animeId}'.trim();
        if (candidate.isNotEmpty && candidate != '0') {
          id = candidate;
          break;
        }
      }
      if (id.isEmpty) {
        final title =
            folder.tasks.isEmpty ? '' : folder.tasks.first.animeTitle.trim();
        if (title.isEmpty) continue;
        id = 'title:$title';
      }
      final latest = await WatchProgress.latest(id);
      if (latest != null) next[folder.key] = latest;
    }
    if (!mounted) return;
    setState(() => _resume = next);
  }

  String _clock(int ms) {
    final total = (ms / 1000).round();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final sec = total % 60;
    final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
    final ss = sec.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: AnimatedBuilder(
        animation: _manager,
        builder: (context, _) {
          final active = [..._manager.active, ..._manager.paused];
          final folders = _manager.folders;
          final readyCount = _manager.readyCount;
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
                    tooltip: 'Pause all downloads',
                    onPressed: active.isEmpty ? null : _manager.pauseAll,
                    icon: const Icon(Icons.pause_circle_outline_rounded),
                  ),
                  IconButton(
                    tooltip: 'Resume all downloads',
                    onPressed: active.isEmpty ? null : _manager.resumeAll,
                    icon: const Icon(Icons.play_circle_outline_rounded),
                  ),
                ]),
                const SizedBox(height: 14),
                _summary(active.length, readyCount),
                _libraryTabs(),
                if (_view == 1)
                  ..._watchlistSection()
                else if (_view == 2)
                  ..._historySection()
                else if (!_started)
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
                  CamSectionTitle('Saved anime',
                      eyebrow:
                          '${folders.length} folders · $readyCount episodes',
                      padding: const EdgeInsets.fromLTRB(0, 24, 0, 10)),
                  if (folders.isEmpty)
                    const CamCard(
                      child: EmptyState(
                        icon: Icons.video_library_outlined,
                        title: 'Nothing saved yet',
                        message:
                            'Downloaded episodes live here, grouped by anime and season, and play with no internet at all.',
                      ),
                    )
                  else ...[
                    if (DeviceStorage.supported)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(children: [
                          Expanded(
                            child: Text(
                              'Completed episodes are copied to '
                              'Download/CamAnime so any player or file manager can open them.',
                              style: const TextStyle(
                                  color: CamColors.inkDim,
                                  fontSize: 11,
                                  height: 1.35),
                            ),
                          ),
                          TextButton.icon(
                            onPressed: DeviceStorage.openDownloads,
                            icon:
                                const Icon(Icons.folder_open_rounded, size: 16),
                            label: const Text('Open'),
                          ),
                        ]),
                      ),
                    for (final folder in folders)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _folderCard(folder),
                      ),
                  ],
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _libraryTabs() {
    const labels = ['Downloads', 'Watchlist', 'History'];
    const icons = [
      Icons.download_rounded,
      Icons.bookmark_rounded,
      Icons.history_rounded
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 14, 0, 2),
      child: Row(children: [
        for (var i = 0; i < labels.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _view = i),
              child: Container(
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _view == i ? CamColors.surfaceAlt : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: _view == i ? CamColors.accent : CamColors.line),
                ),
                child:
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(icons[i],
                      size: 15,
                      color: _view == i ? CamColors.accent : CamColors.inkDim),
                  const SizedBox(width: 5),
                  // Flexible + ellipsis: the three tabs must never overflow
                  // on the narrowest phones (the 430dp test caught 0.4px).
                  Flexible(
                    child: Text(labels[i],
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                            color:
                                _view == i ? CamColors.ink : CamColors.inkDim)),
                  ),
                ]),
              ),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _posterThumb(String image) => ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 44,
          height: 58,
          child: image.isEmpty
              ? Container(
                  color: CamColors.surfaceAlt,
                  alignment: Alignment.center,
                  child: const Icon(Icons.movie_rounded,
                      size: 18, color: CamColors.inkDim))
              : Image.network(image,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                        color: CamColors.surfaceAlt,
                        alignment: Alignment.center,
                        child: const Icon(Icons.movie_rounded,
                            size: 18, color: CamColors.inkDim),
                      )),
        ),
      );

  List<Widget> _watchlistSection() {
    return [
      CamSectionTitle('Watchlist',
          eyebrow: '${_watch.length} saved',
          padding: const EdgeInsets.fromLTRB(0, 20, 0, 10)),
      if (_watch.isEmpty)
        const CamCard(
          child: EmptyState(
            icon: Icons.bookmark_border_rounded,
            title: 'Your watchlist is empty',
            message:
                'Open any anime and tap the bookmark to keep it here for later. It stays on this device.',
          ),
        )
      else
        for (final row in _watch)
          Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: CamCard(
              padding: const EdgeInsets.all(11),
              onTap: () => _openAnime('${row['id']}', '${row['title']}'),
              child: Row(children: [
                _posterThumb('${row['image']}'),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${row['title']}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 13)),
                        const SizedBox(height: 3),
                        Text(
                            '${row['episodes'] ?? 0} episodes · on this device',
                            style: const TextStyle(
                                color: CamColors.inkDim, fontSize: 10.5)),
                      ]),
                ),
                IconButton(
                  tooltip: 'Remove from watchlist',
                  onPressed: () async {
                    await Watchlist.remove('${row['id']}');
                    await _loadLists();
                  },
                  icon: const Icon(Icons.bookmark_remove_rounded,
                      size: 19, color: CamColors.inkDim),
                ),
              ]),
            ),
          ),
    ];
  }

  List<Widget> _historySection() {
    return [
      CamSectionTitle('History',
          eyebrow: '${_history.length} episodes',
          padding: const EdgeInsets.fromLTRB(0, 20, 0, 10)),
      if (_history.isEmpty)
        const CamCard(
          child: EmptyState(
            icon: Icons.history_rounded,
            title: 'Nothing watched yet',
            message:
                'Every episode you play is listed here with how far you got, so you can jump straight back in.',
          ),
        )
      else
        for (final row in _history)
          Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: CamCard(
              padding: const EdgeInsets.all(11),
              onTap: () => _openAnime('${row['id']}', '${row['title']}'),
              child: Row(children: [
                _posterThumb('${row['image']}'),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${row['title']}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 13)),
                        const SizedBox(height: 3),
                        Text(
                          'EP ${row['ep']} · '
                          '${_clock(int.tryParse('${row['posMs']}') ?? 0)}'
                          '${row['finished'] == true ? ' · watched' : ''}',
                          style: const TextStyle(
                              color: CamColors.inkDim, fontSize: 10.5),
                        ),
                      ]),
                ),
                const Icon(Icons.chevron_right_rounded,
                    color: CamColors.inkDim),
              ]),
            ),
          ),
    ];
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
                '${task.qualityLabel}'
                '${task.durationLabel.isEmpty ? '' : ' · ${task.durationLabel}'} · '
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

  /// One anime season = one folder, collapsed until tapped.
  Widget _folderCard(DownloadFolder folder) {
    final open = _expanded.contains(folder.key);
    final exported =
        folder.tasks.where((t) => (t.devicePath ?? '').isNotEmpty).length;
    return CamCard(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      onTap: () => setState(() {
        if (open) {
          _expanded.remove(folder.key);
        } else {
          _expanded.add(folder.key);
        }
      }),
      child: Column(children: [
        Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 56,
              height: 56,
              child: folder.cover.isEmpty
                  ? Container(
                      color: CamColors.surfaceAlt,
                      alignment: Alignment.center,
                      child: const Icon(Icons.video_library_rounded,
                          color: CamColors.inkDim, size: 22),
                    )
                  : Image.network(
                      folder.cover,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        color: CamColors.surfaceAlt,
                        alignment: Alignment.center,
                        child: const Icon(Icons.video_library_rounded,
                            color: CamColors.inkDim, size: 22),
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(folder.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 13.5)),
              const SizedBox(height: 4),
              Text(
                '${folder.subtitle} · ${folder.tasks.length} ep'
                '${folder.tasks.length == 1 ? '' : 's'} · '
                '${compactBytes(folder.bytes)}',
                style: const TextStyle(color: CamColors.inkDim, fontSize: 10.5),
              ),
              const SizedBox(height: 5),
              Row(children: [
                MetaPill('FOLDER',
                    icon: Icons.folder_rounded, color: CamColors.accentAlt),
                const SizedBox(width: 6),
                if (exported > 0)
                  MetaPill(
                    exported == folder.tasks.length
                        ? 'ON DEVICE'
                        : '$exported/${folder.tasks.length} ON DEVICE',
                    icon: Icons.smartphone_rounded,
                    color: CamColors.success,
                  ),
                if (_resume[folder.key] != null) ...[
                  const SizedBox(width: 6),
                  MetaPill(
                    'RESUME EP ${_resume[folder.key]!['ep']} · '
                    '${_clock(int.tryParse('${_resume[folder.key]!['posMs']}') ?? 0)}',
                    icon: Icons.play_arrow_rounded,
                    color: CamColors.accent,
                  ),
                ],
              ]),
            ]),
          ),
          Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
              color: CamColors.inkDim),
        ]),
        if (open) ...[
          const SizedBox(height: 6),
          const Divider(height: 1),
          for (final task in folder.tasks) _folderEpisode(task),
          if (DeviceStorage.supported && !folder.allExported)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => _exportFolder(folder),
                icon: const Icon(Icons.save_alt_rounded, size: 16),
                label: const Text('Save all to device'),
              ),
            ),
          const SizedBox(height: 2),
        ],
      ]),
    );
  }

  Widget _folderEpisode(DownloadTask task) {
    final file = _manager.playableFile(task);
    final onDevice = (task.devicePath ?? '').isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(children: [
        Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: CamColors.surfaceAlt,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: CamColors.line),
          ),
          child: Text('${task.episode}',
              style:
                  const TextStyle(fontWeight: FontWeight.w900, fontSize: 12.5)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Episode ${task.episode} · ${task.audio.toUpperCase()}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 12.5)),
            const SizedBox(height: 2),
            Text(
              '${task.total > 0 ? compactBytes(task.total) : 'Size pending'} · '
              '${task.qualityLabel}'
              '${task.durationLabel.isEmpty ? '' : ' · ${task.durationLabel}'} · '
              '${task.completedLabel}',
              style: const TextStyle(color: CamColors.inkDim, fontSize: 10),
            ),
            if (onDevice)
              Text(
                task.devicePath!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: CamColors.success, fontSize: 9.5),
              ),
          ]),
        ),
        if (task.stage == DownloadStage.paused)
          IconButton(
            tooltip: 'Resume this download',
            onPressed: () => _manager.resume(task.id),
            icon: const Icon(Icons.play_arrow_rounded,
                color: CamColors.accent, size: 21),
          )
        else if (task.stage == DownloadStage.downloading ||
            task.stage == DownloadStage.queued ||
            task.stage == DownloadStage.waitingNetwork)
          IconButton(
            tooltip: 'Pause this download',
            onPressed: () => _manager.pause(task.id),
            icon: const Icon(Icons.pause_rounded,
                color: CamColors.inkDim, size: 21),
          ),
        if (DeviceStorage.supported && !onDevice)
          IconButton(
            tooltip: 'Save to device',
            onPressed: () => _exportOne(task),
            icon: const Icon(Icons.save_alt_rounded,
                color: CamColors.inkDim, size: 19),
          ),
        if (file != null)
          IconButton(
            tooltip: 'Play offline',
            onPressed: () => _playFile(file, task),
            icon: const Icon(Icons.play_circle_fill_rounded,
                color: CamColors.success, size: 27),
          ),
        IconButton(
          tooltip: 'Delete',
          onPressed: () => _confirmRemove(task),
          icon: const Icon(Icons.delete_outline_rounded,
              color: CamColors.inkDim, size: 19),
        ),
      ]),
    );
  }

  Future<void> _exportOne(DownloadTask task) async {
    final location = await _manager.exportToDevice(task);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(location == null
          ? 'Could not copy this episode to device storage.'
          : 'Saved to $location'),
    ));
  }

  Future<void> _exportFolder(DownloadFolder folder) async {
    final saved = await _manager.exportFolder(folder);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(saved == 0
          ? 'Nothing new to copy — those episodes are already on your device.'
          : '$saved episode${saved == 1 ? '' : 's'} saved to Download/CamAnime.'),
    ));
  }

  Future<void> _playFile(File file, DownloadTask task) async {
    final partial = file.path.endsWith('.part');
    // Everything saved for this anime (same title + season) becomes the offline
    // queue, so finishing an episode rolls straight into the next one on disk.
    final queue = <EpisodeSource>[];
    var start = 0;
    for (final folder in _manager.folders) {
      if (folder.key != '${task.animeTitle}|${task.season.trim()}') continue;
      for (final episode in folder.tasks) {
        final playable = _manager.playableFile(episode);
        if (playable == null) continue;
        if (episode.id == task.id) start = queue.length;
        queue.add(EpisodeSource(
          url: playable.path,
          label: '${episode.animeTitle} — Ep ${episode.episode}',
          animeId: '${episode.animeId}',
          animeTitle: episode.animeTitle,
          episode: episode.episode,
          image: episode.image,
          height: episode.height,
        ));
      }
      break;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          url: file.path,
          label: '${task.displayTitle}${partial ? ' (downloading)' : ''}',
          localFile: true,
          episode: task.episode,
          playlist: queue,
          startIndex: start,
          onOpenAnime: (id, title) => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => _AnimeOpener(animeId: id, title: title)),
          ),
        ),
      ),
    );
    await _loadResume();
  }

  Future<void> _confirmRemove(DownloadTask task) async {
    final exported = (task.devicePath ?? '').isNotEmpty;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: CamColors.surface,
        title: const Text('Remove download?'),
        content: Text(
            '${task.displayTitle} will be deleted from CamAnime\'s offline library.'
            '${exported ? '\n\nThe copy on your device (Download/CamAnime) is kept.' : ''}'),
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
