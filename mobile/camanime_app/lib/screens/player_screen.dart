import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../core/cam_ui.dart';
import '../core/models.dart';

/// Premium, distraction-free player with automatic backup-server fallback,
/// episode queue, and recommendations underneath the video surface.
class PlayerScreen extends StatefulWidget {
  final String url;
  final String label;
  final bool localFile;
  final List<EpisodeSource> playlist;
  final int startIndex;
  final bool resume;
  final List<String> mirrors;
  final void Function(String animeId, String title)? onOpenAnime;
  final int? episode;

  /// Resolves the next episode when the queue has no more entries, so the
  /// player can continue a series without the user going back to the detail
  /// page. Returning null means "no next episode exists".
  final Future<EpisodeSource?> Function(int episode)? fetchEpisode;

  /// Other qualities of the *same* episode, so the quality chips can switch
  /// 1080p → 720p → 480p → 360p without leaving the player.
  final List<EpisodeSource> variants;

  const PlayerScreen({
    super.key,
    required this.url,
    required this.label,
    this.localFile = false,
    this.playlist = const [],
    this.startIndex = 0,
    this.resume = false,
    this.mirrors = const [],
    this.onOpenAnime,
    this.episode,
    this.fetchEpisode,
    this.variants = const [],
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  VideoPlayerController? _video;
  ChewieController? _chewie;
  String? _error;
  bool _loading = true;
  bool _switching = false;
  int _urlIndex = 0;
  String _attempt = '';
  bool _autoplayNext = false;
  bool _resumeEnabled = true;
  double _volume = 1.0;
  double _brightness = 1.0;
  int _preferredServer = 0;
  EpisodeSource? _variant;

  /// Quality variants belong to one episode; they are cleared whenever the
  /// player moves on, so a chip can never switch back to the previous episode.
  List<EpisodeSource> _episodeVariants = const [];

  late List<EpisodeSource> playlist;
  int index = 0;
  List<Map> _recommended = const [];
  bool _recsLoading = false;
  int _lastSaveMs = 0;

  EpisodeSource get current => playlist.isEmpty
      ? EpisodeSource(
          url: widget.url,
          label: widget.label,
          mirrors: widget.mirrors,
          episode: widget.episode,
        )
      : playlist[index];

  /// Distinct heights advertised across the resolved sources.
  List<int> get _qualities {
    final set = <int>{};
    for (final source in _variants) {
      if (source.height > 0) set.add(source.height);
    }
    final list = set.toList()..sort((a, b) => b.compareTo(a));
    return list;
  }

  int get _activeHeight => _variant?.height ?? current.height;

  /// The URL currently playing: the chosen quality variant, else the episode's
  /// primary source. Mirrors still provide the automatic server fallback.
  String get _primaryUrl => _variant?.url ?? current.url;

  List<String> get _urls {
    final list = <String>[];
    for (final raw in [_primaryUrl, ...current.mirrors]) {
      if (raw.trim().isNotEmpty && !list.contains(raw)) list.add(raw);
    }
    return list;
  }

  List<EpisodeSource> get _variants => _episodeVariants.isNotEmpty
      ? _episodeVariants
      : (playlist.length > 1 ? playlist : const <EpisodeSource>[]);

  bool get _isPartial => widget.localFile && current.url.endsWith('.part');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    playlist = widget.playlist.isEmpty
        ? [
            EpisodeSource(
              url: widget.url,
              label: widget.label,
              mirrors: widget.mirrors,
              episode: widget.episode,
            )
          ]
        : List.of(widget.playlist);
    index = widget.startIndex.clamp(0, playlist.length - 1);
    _episodeVariants = widget.variants;
    _variant = _episodeVariants.isEmpty ? null : _episodeVariants.first;
    _prefs();
    _loadCurrent();
    _loadRecommendationsWhenIdle();
  }

  Future<void> _prefs() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _autoplayNext = p.getBool('app_autoplay') ?? true;
      _resumeEnabled = p.getBool('app_resume') ?? true;
      _volume = (p.getDouble('player_volume') ?? 1.0).clamp(0.0, 1.0).toDouble();
      _brightness =
          (p.getDouble('player_brightness') ?? 1.0).clamp(0.2, 1.0).toDouble();
    });
    _preferredServer = p.getInt(_preferredKey) ?? 0;
    _applyVolume();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _saveProgress(force: true);
  }

  String get _preferredKey {
    final id = current.animeId;
    return id.isEmpty ? '' : 'player_server_$id';
  }

  void _applyVolume() {
    try {
      _video?.setVolume(_volume);
    } catch (_) {
      // Controller already disposed; the next one gets the volume on init.
    }
  }

  Future<void> _saveTuning() async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble('player_volume', _volume);
    await p.setDouble('player_brightness', _brightness);
  }

  /// Remembers which server actually worked for this anime, so the next
  /// episode starts there instead of re-probing a dead provider first.
  Future<void> _rememberServer(int index) async {
    _preferredServer = index;
    final key = _preferredKey;
    if (key.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    if (index == 0) {
      await p.remove(key);
    } else {
      await p.setInt(key, index);
    }
  }

  Future<void> _loadCurrent() async {
    if (!mounted) return;
    _urlIndex = 0;
    setState(() {
      _loading = true;
      _error = null;
      _attempt = widget.localFile
          ? 'Opening downloaded episode…'
          : 'Connecting to CamAnime servers…';
    });
    await _disposePlayback();
    await _tryUrls();
  }

  Future<void> _tryUrls() async {
    final urls = _urls;
    if (urls.isEmpty) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'No playable source was returned for this episode.';
        });
      }
      return;
    }
    // Start from the server that last worked for this anime, then keep going
    // through the rest: a dead provider is skipped in seconds, not minutes.
    final start = _urlIndex > 0
        ? _urlIndex
        : _preferredServer.clamp(0, urls.length - 1).toInt();
    for (var step = 0; step < urls.length; step++) {
      if (!mounted) return;
      final i = (start + step) % urls.length;
      _urlIndex = i;
      setState(() {
        _attempt = step == 0
            ? 'Connecting…'
            : 'Trying server ${i + 1} of ${urls.length}…';
      });
      VideoPlayerController? video;
      try {
        video = widget.localFile
            ? VideoPlayerController.file(File(urls[i]))
            : VideoPlayerController.networkUrl(Uri.parse(urls[i]));
        await video.initialize().timeout(const Duration(seconds: 15));
        if (!mounted) {
          await video.dispose();
          return;
        }
        if (_resumeEnabled &&
            current.animeId.isNotEmpty &&
            current.episode != null &&
            !widget.localFile) {
          final at = widget.resume
              ? await WatchProgress.position(current.animeId, current.episode!)
              : null;
          if (at != null && at > 0) {
            await video.seekTo(Duration(milliseconds: at));
          }
        }
        video.addListener(_onTick);
        final chewie = ChewieController(
          videoPlayerController: video,
          autoPlay: true,
          looping: false,
          allowFullScreen: true,
          allowPlaybackSpeedChanging: true,
          allowMuting: true,
          showControlsOnInitialize: false,
          errorBuilder: (_, message) => _PlaybackError(
            message: message,
            canRetry: urls.length > i + 1,
            onRetry: () => _nextMirror(),
          ),
        );
        setState(() {
          _video = video;
          _chewie = chewie;
          _loading = false;
          _error = null;
          _attempt = '';
        });
        _applyVolume();
        unawaited(_rememberServer(i));
        return;
      } catch (e) {
        try {
          await video?.dispose();
        } catch (_) {}
        if (!mounted) return;
        if (i + 1 < urls.length) continue;
        setState(() {
          _loading = false;
          _error = widget.localFile
              ? 'This file could not be opened. It may still be downloading — try again in a moment.'
              : 'All ${urls.length} CamAnime servers failed for this episode.';
        });
      }
    }
  }

  void _nextMirror() {
    if (_switching) return;
    _switching = true;
    Future<void>(() async {
      try {
        final urls = _urls;
        if (_urlIndex + 1 >= urls.length) {
          if (mounted) {
            setState(() => _error = 'No backup servers left for this episode.');
          }
          return;
        }
        _urlIndex += 1;
        await _disposePlayback();
        await _tryUrls();
      } finally {
        _switching = false;
      }
    });
  }

  Future<void> _retry() async {
    _urlIndex = 0;
    await _loadCurrent();
  }

  /// Recommendations wait until the episode is actually buffering. Fetching
  /// the whole catalogue at the same moment as the video competed for
  /// bandwidth and made the first frame noticeably slower on mobile data.
  Future<void> _loadRecommendationsWhenIdle() async {
    final p = await SharedPreferences.getInstance();
    if (p.getBool('app_data_saver') ?? false) return;
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    if (!mounted) return;
    await _loadRecommendations();
  }

  Future<void> _loadRecommendations() async {
    setState(() => _recsLoading = true);
    try {
      final response = await http
          .get(Uri.parse('$apiHost/api/v1/catalog/home'))
          .timeout(const Duration(seconds: 18));
      final body = json.decode(response.body) as Map<String, dynamic>;
      final catalog = (body['catalog'] as Map?)?.cast<String, dynamic>() ?? {};
      final pool = <Map>[
        ...((catalog['trending'] as List?) ?? []).whereType<Map>(),
        ...((catalog['popular'] as List?) ?? []).whereType<Map>(),
      ];
      final seen = <String>{};
      final picked = <Map>[];
      for (final item in pool) {
        final id = (item['id'] ?? '').toString();
        if (id.isEmpty || !seen.add(id)) continue;
        if (id == current.animeId) continue;
        picked.add(item);
        if (picked.length >= 9) break;
      }
      if (mounted) setState(() => _recommended = picked);
    } catch (_) {
      // Recommendations are additive; playback never depends on them.
    } finally {
      if (mounted) setState(() => _recsLoading = false);
    }
  }

  void _onTick() {
    final v = _video;
    if (v == null || !v.value.isInitialized) return;
    if (v.value.hasError && _error == null) {
      if (_urlIndex + 1 < _urls.length) {
        _nextMirror();
        return;
      }
    }
    final src = current;
    if (v.value.isCompleted) {
      if (src.animeId.isNotEmpty && src.episode != null) {
        unawaited(WatchProgress.clear(src.animeId, src.episode!));
      }
      _advance();
      return;
    }
    final pos = v.value.position.inMilliseconds;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (pos < 5000 || now - _lastSaveMs < 5000) return;
    _lastSaveMs = now;
    unawaited(_saveProgress());
  }

  Future<void> _saveProgress({bool force = false}) async {
    final v = _video;
    final src = current;
    if (v == null || !v.value.isInitialized) return;
    if (src.animeId.isEmpty || src.episode == null || widget.localFile) return;
    final pos = v.value.position.inMilliseconds;
    final dur = v.value.duration.inMilliseconds;
    if (dur <= 0 || pos >= dur * 0.95) {
      await WatchProgress.clear(src.animeId, src.episode!);
      return;
    }
    if (pos < 5000 && !force) return;
    await WatchProgress.save(
      animeId: src.animeId,
      animeTitle: src.animeTitle.isEmpty ? src.label : src.animeTitle,
      image: src.image,
      episode: src.episode!,
      posMs: pos,
      durMs: dur,
    );
  }

  /// Switches to the source closest to the requested height: an exact match,
  /// otherwise the nearest lower quality, otherwise the nearest higher one.
  Future<void> _selectQuality(int height) async {
    EpisodeSource? best;
    var bestScore = 1 << 30;
    for (final source in _variants) {
      final h = source.height;
      if (h <= 0) continue;
      final score = h == height
          ? -1000
          : (h <= height ? height - h : 1000 + (h - height));
      if (score < bestScore) {
        bestScore = score;
        best = source;
      }
    }
    if (best == null || best.url == _primaryUrl) return;
    _urlIndex = 0;
    setState(() => _variant = best);
    await _disposePlayback();
    await _tryUrls();
  }

  /// Auto-advance a user-built queue, then keep the series going by resolving
  /// the next episode when the user has enabled autoplay in Settings.
  void _advance() {
    if (_switching) return;
    if (index < playlist.length - 1) {
      if (!_autoplayNext && playlist.length == 1) return;
      _switching = true;
      Future<void>(() async {
        try {
          await _disposePlayback();
          if (!mounted) return;
          setState(() {
            index += 1;
            _variant = null;
            _episodeVariants = const [];
            _error = null;
          });
          await _tryUrls();
        } finally {
          _switching = false;
        }
      });
      return;
    }
    final fetch = widget.fetchEpisode;
    if (_autoplayNext && fetch != null && !widget.localFile) {
      final base = current.episode ?? widget.episode;
      if (base == null || base <= 0) return;
      _switching = true;
      Future<void>(() async {
        try {
          final next = await fetch(base + 1);
          if (!mounted) return;
          if (next == null) {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('Episode finished.')));
            return;
          }
          await _disposePlayback();
          if (!mounted) return;
          setState(() {
            playlist = [...playlist, next];
            index = playlist.length - 1;
            _variant = null;
            _episodeVariants = const [];
            _error = null;
          });
          await _tryUrls();
        } finally {
          _switching = false;
        }
      });
      return;
    }
    if (_autoplayNext && mounted && !widget.localFile) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Episode finished.')));
    }
  }

  Future<void> _goTo(int target) async {
    if (target < 0 || target >= playlist.length) return;
    await _disposePlayback();
    if (!mounted) return;
    setState(() {
      index = target;
      _variant = null;
      _episodeVariants = const [];
      _error = null;
    });
    await _tryUrls();
  }

  Future<void> _disposePlayback() async {
    final video = _video;
    _video = null;
    if (video != null) {
      video.removeListener(_onTick);
      try {
        await video.pause();
      } catch (_) {}
    }
    try {
      _chewie?.dispose();
    } catch (_) {}
    _chewie = null;
    try {
      await video?.dispose();
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_saveProgress(force: true));
    _disposePlayback();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final urls = _urls;
    return Scaffold(
      backgroundColor: CamColors.bg,
      appBar: AppBar(
        title: Text(
          playlist.isEmpty ? widget.label : current.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Reload player',
            onPressed: _loading ? null : _retry,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 36),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(CamRadius.lg),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(
                      color: Colors.black,
                      child: _buildSurface(urls),
                    ),
                    if (_brightness < 0.999)
                      IgnorePointer(
                        child: ColoredBox(
                          color: Colors.black
                              .withValues(alpha: (1 - _brightness) * 0.72),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (_attempt.isNotEmpty && _error == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
              child: Row(children: [
                const SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_attempt,
                      style: const TextStyle(
                          color: CamColors.inkDim, fontSize: 11.5)),
                ),
              ]),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Wrap(spacing: 7, runSpacing: 7, children: [
              MetaPill(
                widget.localFile ? 'OFFLINE' : 'STREAM',
                icon: widget.localFile
                    ? Icons.offline_pin_rounded
                    : Icons.podcasts_rounded,
                color: widget.localFile ? CamColors.success : CamColors.info,
              ),
              if (urls.length > 1)
                MetaPill('${urls.length} SERVERS',
                    icon: Icons.dns_rounded, color: CamColors.accentAlt),
              if (_isPartial)
                const MetaPill('PARTIAL · PLAYING AS IT DOWNLOADS',
                    icon: Icons.downloading_rounded, color: CamColors.accent),
              if (!widget.localFile && _resumeEnabled)
                const MetaPill('RESUME ON', color: CamColors.inkDim),
              if (_autoplayNext && !widget.localFile)
                const MetaPill('AUTO-NEXT ON',
                    icon: Icons.skip_next_rounded, color: CamColors.success),
            ]),
          ),
          if (_qualities.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Row(children: [
                const Icon(Icons.high_quality_rounded,
                    size: 17, color: CamColors.inkDim),
                const SizedBox(width: 8),
                Expanded(
                  child: Wrap(spacing: 7, runSpacing: 7, children: [
                    for (final height in _qualities)
                      ChoiceChip(
                        label: Text('${height}p'),
                        selected: _activeHeight == height,
                        onSelected: (_) => _selectQuality(height),
                      ),
                  ]),
                ),
              ]),
            ),
          _tuningCard(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              playlist.isEmpty ? widget.label : current.label,
              style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2),
            ),
          ),
          if (urls.length > 1) ...[
            const CamSectionTitle('Playback source',
                eyebrow: 'Automatic fallback',
                padding: EdgeInsets.fromLTRB(16, 18, 16, 8)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < urls.length; i++)
                    ChoiceChip(
                      label:
                          Text(i == 0 ? 'Server 1 · main' : 'Server ${i + 1}'),
                      selected: _urlIndex == i,
                      onSelected: (_) async {
                        if (_urlIndex == i) return;
                        _urlIndex = i;
                        await _disposePlayback();
                        await _tryUrls();
                      },
                    ),
                ],
              ),
            ),
          ],
          if (playlist.length > 1) _queueSection(),
          _recsSection(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
            child: Row(children: [
              Expanded(
                child: CamGhostButton(
                  label: 'Previous',
                  icon: Icons.skip_previous_rounded,
                  onPressed: index > 0 ? () => _goTo(index - 1) : null,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: CamPrimaryButton(
                  label:
                      index + 1 < playlist.length ? 'Next episode' : 'Replay',
                  icon: index + 1 < playlist.length
                      ? Icons.skip_next_rounded
                      : Icons.replay_rounded,
                  onPressed: () =>
                      index + 1 < playlist.length ? _goTo(index + 1) : _retry(),
                ),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
            child: Text(
              widget.localFile
                  ? (_isPartial
                      ? 'Playing the downloaded part while the rest finishes. Everything already saved is watchable now.'
                      : 'Playing the full episode stored on this device. No internet needed.')
                  : 'Streaming from CamAnime. If a server stalls, the app switches to the next one automatically.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: CamColors.inkDim, fontSize: 11.5, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  /// Volume and picture brightness, adjustable without leaving the episode.
  /// Brightness is applied as a dimming overlay, so it works on every device.
  Widget _tuningCard() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
        child: CamCard(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Column(children: [
            Row(children: [
              Icon(
                _volume == 0
                    ? Icons.volume_off_rounded
                    : Icons.volume_up_rounded,
                size: 18,
                color: CamColors.inkDim,
              ),
              Expanded(
                child: Slider(
                  value: _volume,
                  activeColor: CamColors.accent,
                  onChanged: (v) {
                    setState(() => _volume = v);
                    _applyVolume();
                  },
                  onChangeEnd: (_) => _saveTuning(),
                ),
              ),
              SizedBox(
                width: 40,
                child: Text('${(_volume * 100).round()}%',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        fontSize: 10.5, color: CamColors.inkDim)),
              ),
            ]),
            Row(children: [
              const Icon(Icons.brightness_6_rounded,
                  size: 18, color: CamColors.inkDim),
              Expanded(
                child: Slider(
                  value: _brightness,
                  min: 0.2,
                  activeColor: CamColors.accent,
                  onChanged: (v) => setState(() => _brightness = v),
                  onChangeEnd: (_) => _saveTuning(),
                ),
              ),
              SizedBox(
                width: 40,
                child: Text('${(_brightness * 100).round()}%',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        fontSize: 10.5, color: CamColors.inkDim)),
              ),
            ]),
          ]),
        ),
      );

  Widget _buildSurface(List<String> urls) {
    if (_error != null) {
      return _PlaybackError(
        message: _error!,
        canRetry: true,
        onRetry: _retry,
      );
    }
    if (_loading || _chewie == null) {
      return const Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(strokeWidth: 2.4),
          SizedBox(height: 12),
          Text('Loading episode…',
              style: TextStyle(color: CamColors.inkDim, fontSize: 12)),
        ]),
      );
    }
    return Chewie(controller: _chewie!);
  }

  Widget _queueSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      CamSectionTitle(
        'Queue',
        eyebrow: '${index + 1} of ${playlist.length}',
        action: Text('${playlist.length} episodes',
            style: const TextStyle(color: CamColors.inkDim, fontSize: 11)),
      ),
      for (var i = 0; i < playlist.length; i++)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 7),
          child: CamCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            color: i == index ? CamColors.surfaceHigh : CamColors.surface,
            onTap: i == index ? null : () => _goTo(i),
            child: Row(children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: i == index ? CamColors.accent : CamColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: i == index
                    ? const Icon(Icons.graphic_eq_rounded,
                        size: 16, color: Colors.black)
                    : Text('${i + 1}',
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w800)),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  playlist[i].label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
              ),
              if (playlist[i].mirrors.isNotEmpty)
                MetaPill('${playlist[i].mirrors.length + 1} src',
                    color: CamColors.inkDim),
            ]),
          ),
        ),
    ]);
  }

  Widget _recsSection() {
    if (_recsLoading && _recommended.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 22, 16, 0),
        child: CamSkeleton(height: 110, radius: 16),
      );
    }
    if (_recommended.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const CamSectionTitle('More to watch', eyebrow: 'From CamAnime'),
      SizedBox(
        height: 196,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: _recommended.length,
          separatorBuilder: (_, __) => const SizedBox(width: 10),
          itemBuilder: (_, i) {
            final item = _recommended[i];
            final title = (item['title'] ?? 'Anime').toString();
            final id = (item['id'] ?? '').toString();
            final image = (item['image'] ?? item['banner'] ?? '').toString();
            return GestureDetector(
              onTap: () async {
                if (widget.onOpenAnime != null) {
                  widget.onOpenAnime!(id, title);
                  return;
                }
                await _startRecommendation(id, title, image);
              },
              child: SizedBox(
                width: 104,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: AspectRatio(
                        aspectRatio: 2 / 2.85,
                        child: image.isEmpty
                            ? const ColoredBox(
                                color: CamColors.surfaceAlt,
                                child: Icon(Icons.movie_outlined,
                                    color: CamColors.inkDim))
                            : Image.network(
                                image,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => const ColoredBox(
                                  color: CamColors.surfaceAlt,
                                  child: Icon(Icons.movie_outlined,
                                      color: CamColors.inkDim),
                                ),
                                loadingBuilder: (_, child, progress) =>
                                    progress == null
                                        ? child
                                        : const ColoredBox(
                                            color: CamColors.surfaceAlt),
                              ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11.5, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    ]);
  }

  Future<void> _startRecommendation(
      String animeId, String title, String image) async {
    if (animeId.isEmpty) return;
    try {
      final response = await http.get(Uri.parse(
          '$apiHost/api/episode-sources/${Uri.encodeComponent(animeId)}/1?audio=sub'));
      final bundle = json.decode(response.body) as Map<String, dynamic>;
      final servers = (bundle['servers'] as List?) ?? [];
      final urls = <String>[];
      for (final raw in servers) {
        if (raw is! Map) continue;
        final mode = (raw['playback_mode'] ?? '').toString();
        if (mode != 'mp4' && mode != 'hls') continue;
        final path = (raw['stream_url'] ?? '').toString();
        if (path.isEmpty) continue;
        final abs = path.startsWith('http') ? path : '$apiHost$path';
        if (!urls.contains(abs)) urls.add(abs);
      }
      if (!mounted) return;
      if (urls.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No playable server for that anime yet.')));
        return;
      }
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            url: urls.first,
            mirrors: urls.skip(1).toList(),
            label: '$title — Ep 1 (SUB)',
            onOpenAnime: widget.onOpenAnime,
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not reach the server for that anime.')));
      }
    }
  }
}

class _PlaybackError extends StatelessWidget {
  final String message;
  final bool canRetry;
  final VoidCallback onRetry;
  const _PlaybackError({
    required this.message,
    required this.canRetry,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.cloud_off_rounded,
                  color: CamColors.inkDim, size: 34),
              const SizedBox(height: 10),
              Text(message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: CamColors.inkDim, fontSize: 12, height: 1.4)),
              if (canRetry) ...[
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Retry / next server'),
                ),
              ],
            ]),
          ),
        ),
      );
}
