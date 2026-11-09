import 'dart:io';

import 'package:flutter/material.dart';

import '../core/cam_ui.dart';
import '../core/downloads.dart';

/// Real per-episode metadata supplied by the catalogue (`streaming_metadata`).
/// Only episodes the backend actually knows about get a title or thumbnail;
/// nothing is generated for the rest.
class EpisodePreview {
  final int number;
  final String title;
  final String image;

  const EpisodePreview({
    required this.number,
    this.title = '',
    this.image = '',
  });

  static Map<int, EpisodePreview> fromMetadata(List? raw) {
    final out = <int, EpisodePreview>{};
    for (final entry in raw ?? const []) {
      if (entry is! Map) continue;
      final rawTitle = (entry['title'] ?? '').toString().trim();
      final match = RegExp(r'[Ee]p(?:isode)?\s*(\d+)').firstMatch(rawTitle);
      final number = int.tryParse(match?.group(1) ?? '') ??
          int.tryParse('${entry['episode'] ?? entry['number'] ?? ''}');
      if (number == null) continue;
      var title = rawTitle
          .replaceFirst(
              RegExp(r'^.*?[Ee]p(?:isode)?\s*\d+\s*[-:–—|.]*\s*'), '')
          .replaceFirst(
              RegExp(r'\s*[-–—|]\s*[Ee]p(?:isode)?\s*\d+\s*$'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      // A title that only repeats the episode number is not a real title.
      if (RegExp(r'^[Ee]p(?:isode)?\s*\d+$').hasMatch(title)) title = '';
      if (title.length > 90) title = '${title.substring(0, 90)}…';
      out[number] = EpisodePreview(
        number: number,
        title: title,
        image: (entry['thumbnail'] ?? '').toString(),
      );
    }
    return out;
  }
}

/// Compact, lazily-built episode browser for the detail page.
///
/// Rows are built only as they scroll into view, so a 500-episode series never
/// decodes hundreds of thumbnails at once. Downloads, partial playback and
/// watch progress are read from the same managers the rest of the app uses.
class EpisodeBoard extends StatefulWidget {
  final int animeId;
  final int totalEpisodes;
  final int? currentEpisode;
  final Set<int> selected;
  final Map<int, EpisodePreview> previews;
  final Map<int, double> progress;
  final ValueChanged<int> onPlay;
  final void Function(int ep, bool select) onToggleSelect;
  final ValueChanged<int> onDownload;
  final Widget Function(String url) imageBuilder;

  const EpisodeBoard({
    super.key,
    required this.animeId,
    required this.totalEpisodes,
    required this.selected,
    required this.onPlay,
    required this.onToggleSelect,
    required this.onDownload,
    required this.imageBuilder,
    this.previews = const {},
    this.progress = const {},
    this.currentEpisode,
  });

  @override
  State<EpisodeBoard> createState() => _EpisodeBoardState();
}

class _EpisodeBoardState extends State<EpisodeBoard> {
  static const int _pageSize = 60;
  static const double _rowHeight = 74;
  final _manager = DownloadManager.instance;
  int _page = 0;

  int get _pages => widget.totalEpisodes == 0
      ? 0
      : ((widget.totalEpisodes - 1) ~/ _pageSize) + 1;

  bool get _selectionMode => widget.selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    final current = widget.currentEpisode;
    if (current != null && current > 0) {
      _page =
          ((current - 1) ~/ _pageSize).clamp(0, _pages == 0 ? 0 : _pages - 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.totalEpisodes == 0) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
        decoration: BoxDecoration(
          color: CamColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: CamColors.line),
        ),
        child: const Row(children: [
          Icon(Icons.info_outline_rounded, color: CamColors.inkDim, size: 17),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'No episode list has been published for this title yet.',
              style: TextStyle(
                  color: CamColors.inkDim, fontSize: 11.5, height: 1.45),
            ),
          ),
        ]),
      );
    }

    return AnimatedBuilder(
      animation: _manager,
      builder: (context, _) {
        final start = _page * _pageSize;
        final end = (start + _pageSize).clamp(0, widget.totalEpisodes);
        final count = end - start;
        final height =
            (count * _rowHeight).clamp(_rowHeight, _rowHeight * 5.8).toDouble();
        final ready =
            _manager.completed.where((t) => t.animeId == widget.animeId).length;
        final active =
            _manager.active.where((t) => t.animeId == widget.animeId).length;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (ready > 0 || active > 0) ...[
              Row(children: [
                if (ready > 0)
                  MetaPill('$ready offline',
                      icon: Icons.offline_pin_rounded,
                      color: CamColors.success),
                if (ready > 0 && active > 0) const SizedBox(width: 7),
                if (active > 0)
                  MetaPill('$active downloading',
                      icon: Icons.downloading_rounded, color: CamColors.accent),
              ]),
              const SizedBox(height: 10),
            ],
            if (_pages > 1) ...[
              SizedBox(
                height: 30,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _pages,
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (_, i) {
                    final from = i * _pageSize + 1;
                    final to =
                        ((i + 1) * _pageSize).clamp(0, widget.totalEpisodes);
                    final active = i == _page;
                    return InkWell(
                      borderRadius: BorderRadius.circular(7),
                      onTap: () => setState(() => _page = i),
                      child: Container(
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: active
                              ? CamColors.accent.withValues(alpha: 0.14)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(7),
                          border: Border.all(
                              color:
                                  active ? CamColors.accent : CamColors.line),
                        ),
                        child: Text(
                          '$from–$to',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight:
                                active ? FontWeight.w800 : FontWeight.w600,
                            color: active ? CamColors.accent : CamColors.inkDim,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
            Container(
              decoration: BoxDecoration(
                color: CamColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: CamColors.line),
              ),
              clipBehavior: Clip.antiAlias,
              child: SizedBox(
                height: height,
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  itemExtent: _rowHeight,
                  itemCount: count,
                  itemBuilder: (_, i) => _row(start + i + 1),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _selectionMode
                  ? 'Selection mode — tap episodes to add or remove them from the queue.'
                  : 'Tap to play · long-press to select episodes for a queue or a download batch.',
              style: const TextStyle(
                  color: CamColors.inkDim, fontSize: 10.5, height: 1.4),
            ),
          ],
        );
      },
    );
  }

  Widget _row(int ep) {
    final task = _manager.taskFor(widget.animeId, ep);
    final selected = widget.selected.contains(ep);
    final completed = task?.stage == DownloadStage.completed;
    final downloading = task != null &&
        (task.stage == DownloadStage.downloading ||
            task.stage == DownloadStage.queued);
    final waiting = task?.stage == DownloadStage.waitingNetwork;
    final paused = task?.stage == DownloadStage.paused ||
        task?.stage == DownloadStage.failed;
    final playablePart = task != null &&
        task.stage != DownloadStage.completed &&
        _manager.playableFile(task) != null;
    final preview = widget.previews[ep];
    final watched = (widget.progress[ep] ?? 0).clamp(0.0, 1.0);
    final isCurrent = widget.currentEpisode == ep;

    final String? status;
    Color statusColor = CamColors.inkDim;
    if (completed) {
      status = 'Downloaded · plays offline';
      statusColor = CamColors.success;
    } else if (downloading) {
      final pct =
          task.progress == null ? null : '${(task.progress! * 100).round()}%';
      status = pct == null ? 'Downloading…' : 'Downloading · $pct';
      statusColor = CamColors.accent;
    } else if (playablePart) {
      status = 'Playable while it downloads';
      statusColor = CamColors.accent;
    } else if (waiting) {
      status = 'Waiting for connection';
      statusColor = CamColors.info;
    } else if (paused) {
      status = 'Download paused';
      statusColor = CamColors.info;
    } else if (watched > 0.01) {
      status = 'Watched · ${(watched * 100).round()}%';
      statusColor = CamColors.inkDim;
    } else if (isCurrent) {
      status = 'Now playing';
      statusColor = CamColors.accent;
    } else {
      status = null;
    }

    return Material(
      color: selected
          ? CamColors.accent.withValues(alpha: 0.07)
          : Colors.transparent,
      child: InkWell(
        onTap: () => _selectionMode
            ? widget.onToggleSelect(ep, !selected)
            : widget.onPlay(ep),
        onLongPress: () => widget.onToggleSelect(ep, !selected),
        child: Container(
          height: _rowHeight,
          decoration: const BoxDecoration(
            border:
                Border(bottom: BorderSide(color: CamColors.line, width: 0.7)),
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                width: selected ? 2.5 : 0,
                color: CamColors.accent,
              ),
              if (_selectionMode)
                Padding(
                  padding: const EdgeInsets.only(left: 10, right: 2),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected ? CamColors.accent : Colors.transparent,
                      border: Border.all(
                          color: selected ? CamColors.accent : CamColors.line,
                          width: 1.5),
                    ),
                    child: selected
                        ? const Icon(Icons.check_rounded,
                            size: 14, color: Colors.black)
                        : null,
                  ),
                ),
              const SizedBox(width: 10),
              _thumb(ep, preview, completed, downloading, task),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (preview?.title.isNotEmpty ?? false)
                          ? 'Ep $ep · ${preview!.title}'
                          : 'Episode $ep',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            isCurrent ? FontWeight.w800 : FontWeight.w700,
                        color: CamColors.ink,
                      ),
                    ),
                    const SizedBox(height: 3),
                    if (status != null)
                      Text(
                        status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 10.5,
                            color: statusColor,
                            fontWeight: FontWeight.w600),
                      )
                    else
                      Text(
                        'Episode $ep',
                        style: const TextStyle(
                            fontSize: 10.5, color: CamColors.inkDim),
                      ),
                    if (watched > 0.01 ||
                        (downloading && task.progress != null))
                      Padding(
                        padding: const EdgeInsets.only(top: 5, right: 10),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: downloading ? task.progress : watched,
                            minHeight: 2,
                            backgroundColor: CamColors.surfaceHigh,
                            valueColor: AlwaysStoppedAnimation(downloading
                                ? CamColors.accent
                                : CamColors.info),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              _trailing(ep, completed, downloading, playablePart, task),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }

  Widget _thumb(int ep, EpisodePreview? preview, bool completed,
      bool downloading, DownloadTask? task) {
    final hasImage = preview != null && preview.image.isNotEmpty;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 88,
        height: 50,
        child: Stack(fit: StackFit.expand, children: [
          if (hasImage)
            widget.imageBuilder(preview.image)
          else
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [CamColors.surfaceAlt, CamColors.surfaceHigh],
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                '$ep',
                style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    color: CamColors.inkDim),
              ),
            ),
          if (hasImage)
            Positioned(
              left: 4,
              bottom: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('$ep',
                    style: const TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        color: Colors.white)),
              ),
            ),
          if (completed)
            const Positioned(
              right: 4,
              top: 4,
              child: Icon(Icons.offline_pin_rounded,
                  size: 13, color: CamColors.success),
            )
          else if (downloading || task?.stage == DownloadStage.paused)
            Positioned(
              right: 4,
              top: 4,
              child: SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
                  value: task?.progress,
                  color: CamColors.accent,
                  backgroundColor: Colors.black45,
                ),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _trailing(int ep, bool completed, bool downloading, bool playablePart,
      DownloadTask? task) {
    if (completed) {
      return IconButton(
        tooltip: 'Play offline',
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.play_arrow_rounded,
            size: 21, color: CamColors.success),
        onPressed: () => widget.onPlay(ep),
      );
    }
    if (downloading) {
      return IconButton(
        tooltip: 'Downloading — see Library',
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.downloading_rounded,
            size: 20, color: CamColors.accent),
        onPressed: null,
      );
    }
    return IconButton(
      tooltip: 'Download episode $ep',
      visualDensity: VisualDensity.compact,              icon: Icon(
              playablePart
                  ? Icons.download_done_rounded
                  : Icons.download_for_offline_outlined,
              size: 20,
              color: playablePart ? CamColors.accent : CamColors.inkDim,
            ),
            onPressed: () => widget.onDownload(ep),
    );
  }
}

bool isPartialPath(File file) => file.path.endsWith('.part');
