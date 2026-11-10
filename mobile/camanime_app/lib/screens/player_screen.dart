import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/cam_ui.dart';
import '../core/mini_player.dart';
import '../core/models.dart';

/// Distraction-free player.
///
/// The video is the whole interface: controls appear on a tap and disappear
/// again after a few seconds of inactivity. Everything secondary (quality,
/// speed, autoplay, episode list) lives in a bottom sheet, and the mini-player
/// shares the exact same controller so pausing/seek never desynchronises.
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

  /// Resolves the next episode in the *currently selected* audio language.
  /// Returning null means there is no next episode.
  final Future<EpisodeSource?> Function(int episode)? fetchEpisode;

  /// Other qualities of the same episode.
  final List<EpisodeSource> variants;

  /// Set when the mini-player hands its live session back to the full player.
  final MiniPlayback? handoff;

  /// Preferred aspect ratio for the video surface when the source does not report
  /// one. 16:9 is the default for most anime streams; 4:3 is still common for
  /// older or low-res episodes that do not publish a real aspect ratio.

  const PlayerScreen({
    super.key,
    required this.url,
    required this.label,
    this.localFile = false,
    this.playlist = const [],
    this.startIndex = 0,
    this.resume = true,
    this.mirrors = const [],
    this.onOpenAnime,
    this.episode,
    this.fetchEpisode,
    this.variants = const [],
    this.handoff,
    this.animeId,
    this.audio,
    this.onAudioSwitch,
  });

  final String? animeId;
  final String? audio;
  final Future<String?> Function(String newAudio)? onAudioSwitch;

  // -- Deprecated explicitAspect kept for binary compatibility with callers --

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  Timer? _hideTimer;
  int? _dragMs;
  VideoPlayerController? _video;

  // Control overlay.
  bool _showControls = true;
  bool _switching = false;

  String _currentAudio = 'sub';
  bool _autoSkipIntro = true;
  bool _autoSkipOutro = true;
  bool _introSkipped = false;
  bool _outroHandled = false;
  double _speed = 1.0;
  double _volume = 1.0;
  double _brightness = 1.0;
  bool _fullscreen = false;
  bool _ended = false;
  bool _loading = true;
  String? _error;

  int _posMs = 0;
  int _durMs = 0;
  int _lastSaveMs = 0;
  int _urlIndex = 0;
  String _attempt = '';

  /// Guard against runaway automatic episode chains.
  int _autoHops = 0;
  bool _closing = false;
  bool _advancing = false;

  /// Quality variants belong to one episode; cleared whenever the player moves
  /// on so a chip can never switch back to the previous episode.
  List<EpisodeSource> _episodeVariants = const [];

  late List<EpisodeSource> playlist;
  int index = 0;
  List<Map> _recommended = const [];
  bool _recsLoading = false;
  bool _autoplayNext = true;
  bool _resumeEnabled = true;
  int _preferredServer = 0;
  bool _dataSaver = false;
  bool _qualityFallbackTried = false;

  bool _awake = false;
  late bool _local;
  EpisodeSource? _variant;

  static const MethodChannel _playerChannel = MethodChannel('camanime/player');

  EpisodeSource get current => playlist[index];

  List<int> get _qualities {
    final set = <int>{};
    for (final source in _variants) {
      if (source.height > 0) set.add(source.height);
    }
    final list = set.toList()..sort((a, b) => b.compareTo(a));
    return list;
  }

  int get _activeHeight => _variant?.height ?? current.height;

  String get _progressId {
    final src = current;
    if (src.animeId.isNotEmpty) return src.animeId;
    final title = src.animeTitle.trim();
    return title.isEmpty ? '' : 'title:$title';
  }

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

  /// True while an episode is queued after this one, or when the live source
  /// can be resolved by the caller (series continues past the saved queue).
  bool get _canHaveNext =>
      index + 1 < playlist.length ||
      (widget.fetchEpisode != null && (current.episode ?? 0) > 0);

  String get _preferredKey {
    final id = current.animeId;
    return id.isEmpty ? '' : 'player_server_$id';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _local = widget.localFile;
    _currentAudio = widget.audio ?? 'sub';
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
    // Start on the episode's default/source rendition. A quality chip only
    // takes over after the viewer picks one, and a failed pick falls back here.
    _variant = null;
    _boot();
    _loadRecommendationsWhenIdle();
  }

  @override
  void deactivate() {
    super.deactivate();
  }

  @override
  void dispose() {
    _closing = true;
    _hideTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _releaseAwake();
    unawaited(_saveProgress(force: true));
    _disposePlayback();
    // Leave the device exactly as it was found: system brightness and normal
    // orientation are restored when the player closes.
    _playerChannel.invokeMethod('resetBrightness');
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _boot() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    _autoplayNext = p.getBool('app_autoplay') ?? true;
    _resumeEnabled = p.getBool('app_resume') ?? true;
    _speed = (p.getDouble('player_speed') ?? 1.0).clamp(0.5, 2.0).toDouble();
    _volume = (p.getDouble('player_volume') ?? 1.0).clamp(0.0, 1.0).toDouble();
    _brightness =
        (p.getDouble('player_brightness') ?? 1.0).clamp(0.05, 1.0).toDouble();
    _autoSkipIntro = p.getBool('player_skip_intro') ?? true;
    _autoSkipOutro = p.getBool('player_skip_outro') ?? true;
    _dataSaver = p.getBool('app_data_saver') ?? false;
    if (_dataSaver && _episodeVariants.isNotEmpty) {
      final low = _episodeVariants
          .where((s) => s.height > 0 && s.height <= 480)
          .toList()
        ..sort((a, b) => a.height.compareTo(b.height));
      if (low.isNotEmpty) _variant = low.first;
    }
    if (_brightness < 0.99) unawaited(_applyBrightness(_brightness));
    _preferredServer = p.getInt(_preferredKey) ?? 0;
    final live = widget.handoff;
    if (live != null && live.controller.value.isInitialized) {
      _adopt(live);
      return;
    }
    await _loadCurrent();
  }

  void _switchAudio(String newAudio) async {
    if (newAudio == _currentAudio || widget.onAudioSwitch == null) return;
    setState(() {
      _switching = true;
      _currentAudio = newAudio;
    });
    try {
      final newUrl = await widget.onAudioSwitch!(newAudio);
      if (!mounted) return;
      if (newUrl != null) {
        await _disposePlayback();
        final controller = widget.localFile
            ? VideoPlayerController.file(File(newUrl))
            : VideoPlayerController.networkUrl(Uri.parse(newUrl));
        await controller.initialize().timeout(const Duration(seconds: 15));
        if (!mounted) {
          await controller.dispose();
          return;
        }
        _video = controller;
        _video!.addListener(_onTick);
        if (widget.resume &&
            _progressId.isNotEmpty &&
            current.episode != null) {
          final at =
              await WatchProgress.position(_progressId, current.episode!);
          if (at != null && at > 0) {
            await _video!.seekTo(Duration(seconds: at));
          }
        }
        await _video!.play();
        _snack(
            _currentAudio == 'dub'
                ? 'Now playing English dub (DUB)'
                : 'Now playing English subtitles (SUB)');
        setState(() {
          _loading = false;
          _error = null;
          _switching = false;
          _attempt = '';
        });
      } else if (mounted) {
        setState(() {
          _switching = false;
          _error = 'Could not switch audio.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _switching = false;
          _error = 'Could not switch audio.';
        });
      }
    }
  }

  /// Continues the episode the mini-player was playing, on its own controller.
  void _adopt(MiniPlayback live) {
    final controller = live.controller;
    controller.addListener(_onTick);
    _video = controller;
    _posMs = controller.value.position.inMilliseconds;
    _durMs = controller.value.duration.inMilliseconds;
    setState(() {
      _loading = false;
      _error = null;
      _attempt = '';
      _ended = false;
    });
    _applySpeed();
    _scheduleHide();
    if (!controller.value.isPlaying) unawaited(controller.play());
  }

  Future<void> _holdAwake() async {
    if (_awake) return;
    _awake = true;
    try {
      await WakelockPlus.enable();
    } catch (_) {
      _awake = false;
    }
  }

  void _releaseAwake() {
    if (!_awake) return;
    _awake = false;
    try {
      WakelockPlus.disable();
    } catch (_) {}
  }

  void _applySpeed() {
    try {
      _video?.setPlaybackSpeed(_speed);
    } catch (_) {}
  }

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
    _introSkipped = false;
    _outroHandled = false;
    _qualityFallbackTried = false;
    _urlIndex = 0;
    setState(() {
      _loading = true;
      _error = null;
      _ended = false;
      _attempt = _local
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
        video = _local
            ? VideoPlayerController.file(File(urls[i]))
            : VideoPlayerController.networkUrl(Uri.parse(urls[i]));
        await video.initialize().timeout(const Duration(seconds: 15));
        if (!mounted) {
          await video.dispose();
          return;
        }
        if (_resumeEnabled &&
            _progressId.isNotEmpty &&
            current.episode != null) {
          final at = widget.resume
              ? await WatchProgress.position(_progressId, current.episode!)
              : null;
          if (at != null && at > 0) {
            await video.seekTo(Duration(milliseconds: at));
          }
        }
        video.addListener(_onTick);
        setState(() {
          _video = video;
          _loading = false;
          _error = null;
          _attempt = '';
          _ended = false;
        });
        await video.setPlaybackSpeed(_speed);
        await video.setVolume(_volume);
        await video.play();
        unawaited(_rememberServer(i));
        _scheduleHide();
        return;
      } catch (e) {
        try {
          await video?.dispose();
        } catch (_) {}
        if (!mounted) return;
        if (i + 1 < urls.length) continue;
        if (!_local && _variant != null && !_qualityFallbackTried) {
          // The chosen pixel failed to initialise. Return to the episode's
          // default/source rendition rather than declaring the episode dead.
          _qualityFallbackTried = true;
          _snack('That quality did not play — back to the source quality.');
          setState(() {
            _variant = null;
            _urlIndex = 0;
            _attempt = 'Switching back to source quality…';
          });
          await _tryUrls();
          return;
        }
        setState(() {
          _loading = false;
          _error = _local
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
    _autoHops = 0;
    _qualityFallbackTried = false;
    await _loadCurrent();
  }

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

  void _maybeAutoSkip(int pos, int duration) {
    if (!_autoSkipIntro) return;
    if (_introSkipped) return;
    if (duration <= 300000) return;
    if (pos > 4000 && pos < 92000) {
      _introSkipped = true;
      unawaited(_seekTo(90000));
    }
    if (_autoSkipOutro &&
        !_outroHandled &&
        _canHaveNext &&
        duration - pos <= 80000 &&
        pos > 40000) {
      _outroHandled = true;
      unawaited(_goNext(auto: true));
      return;
    }
    if (_autoSkipOutro &&
        !_outroHandled &&
        !_canHaveNext &&
        duration - pos <= 80000 &&
        pos > 40000) {
      _outroHandled = true;
      unawaited(_seekTo(duration - 15000));
      _snack('Ending reached');
    }
  }

  void _onTick() {
    final v = _video;
    if (v == null || !v.value.isInitialized) return;
    if (v.value.isPlaying) {
      unawaited(_holdAwake());
    } else {
      _releaseAwake();
    }
    if (v.value.hasError && _error == null) {
      if (_urlIndex + 1 < _urls.length) {
        _nextMirror();
        return;
      }
    }
    if (v.value.isCompleted) {
      _onEnded();
      return;
    }
    final pos = v.value.position.inMilliseconds;
    _maybeAutoSkip(pos, v.value.duration.inMilliseconds);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastSaveMs > 500 || _dragMs == null) {
      _lastSaveMs = now;
      if (mounted) {
        setState(() {
          _posMs = pos;
          _durMs = v.value.duration.inMilliseconds;
        });
      }
    }
    if (pos < 5000) return;
    if (now % 10000 > 600) return;
    unawaited(_saveProgress());
  }

  /// The episode actually reached its end. Autoplay only runs here — never on a
  /// manual pause, a minimize, or a close.
  Future<void> _onEnded() async {
    if (_ended || _closing || !mounted) return;
    final src = current;
    if (_progressId.isNotEmpty && src.episode != null) {
      unawaited(WatchProgress.clear(_progressId, src.episode!));
    }
    setState(() {
      _ended = true;
      _showControls = true;
    });
    _hideTimer?.cancel();
    if (!_autoplayNext) return;
    await _goNext(auto: true);
  }

  Future<void> _saveProgress({bool force = false}) async {
    final v = _video;
    final src = current;
    if (v == null || !v.value.isInitialized) return;
    if (_progressId.isEmpty || src.episode == null) return;
    final pos = v.value.position.inMilliseconds;
    final dur = v.value.duration.inMilliseconds;
    if (dur <= 0 || pos >= dur * 0.95) {
      await WatchProgress.clear(_progressId, src.episode!);
      return;
    }
    if (pos < 5000 && !force) return;
    await WatchProgress.save(
      animeId: _progressId,
      animeTitle: src.animeTitle.isEmpty ? src.label : src.animeTitle,
      image: src.image,
      episode: src.episode!,
      posMs: pos,
      durMs: dur,
    );
  }



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
    _qualityFallbackTried = false;
    _urlIndex = 0;
    setState(() => _variant = best);
    await _disposePlayback();
    await _tryUrls();
  }

  /// Moves to the next episode of *this* anime and *this* audio language.
  ///
  /// The next source is resolved before anything is torn down, so a provider
  /// failure leaves the current episode playing and offers a retry instead of
  /// silently jumping to an unrelated title.
  Future<void> _goNext({bool auto = false}) async {
    if (_advancing || _closing) return;
    if (auto && _autoHops >= 30) {
      _snack('Automatic playback stopped after 30 episodes.');
      return;
    }
    _advancing = true;
    _hideTimer?.cancel();
    setState(() {});
    try {
      await _saveProgress(force: true);
      EpisodeSource? next;
      if (index + 1 < playlist.length) {
        next = playlist[index + 1];
      } else {
        final fetch = widget.fetchEpisode;
        final base = current.episode ?? widget.episode;
        if (fetch == null || base == null || base <= 0) {
          _snack('No next episode is available for this title.');
          return;
        }
        next = await fetch(base + 1);
        if (next == null || next.url.trim().isEmpty) {
          _snack(
            'Episode ${base + 1} is not available in this language right now.',
            action: SnackBarAction(label: 'Retry', onPressed: () => _goNext()),
          );
          return;
        }
      }
      if (!mounted) return;
      await _disposePlayback();
      if (!mounted) return;
      setState(() {
        if (index + 1 < playlist.length) {
          index += 1;
        } else {
          playlist = [...playlist, next!];
          index = playlist.length - 1;
        }
        _variant = null;
        _episodeVariants = const [];
        _qualityFallbackTried = false;
        _error = null;
        _ended = false;
        _posMs = 0;
        _durMs = 0;
        _local = false;
      });
      if (auto) _autoHops += 1;
      await _tryUrls();
    } catch (_) {
      if (!mounted) return;
      _snack(
        'Could not start the next episode. Check your connection.',
        action: SnackBarAction(label: 'Retry', onPressed: () => _goNext()),
      );
    } finally {
      _advancing = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _goTo(int target) async {
    if (target < 0 || target >= playlist.length || _advancing) return;
    _advancing = true;
    try {
      await _saveProgress(force: true);
      await _disposePlayback();
      if (!mounted) return;
      setState(() {
        index = target;
        _variant = null;
        _episodeVariants = const [];
        _error = null;
        _ended = false;
        _autoHops = 0;
      });
      await _tryUrls();
    } finally {
      _advancing = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _togglePlay() async {
    final v = _video;
    if (v == null || !v.value.isInitialized) return;
    if (_ended) {
      await v.seekTo(Duration.zero);
      setState(() => _ended = false);
      await v.play();
    } else if (v.value.isPlaying) {
      await v.pause();
    } else {
      await v.play();
    }
    _showControlsNow();
    setState(() {});
  }

  Future<void> _skip(int seconds) async {
    final v = _video;
    if (v == null || !v.value.isInitialized) return;
    final target = v.value.position + Duration(seconds: seconds);
    final end = v.value.duration;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (end > Duration.zero && target > end ? end : target);
    await v.seekTo(clamped);
    _showControlsNow();
    setState(() {
      _posMs = clamped.inMilliseconds;
      if (_ended && clamped < end) _ended = false;
    });
  }

  Future<void> _seekTo(int ms) async {
    final v = _video;
    if (v == null || !v.value.isInitialized) return;
    final target = ms.clamp(0, v.value.duration.inMilliseconds);
    await v.seekTo(Duration(milliseconds: target));
    if (mounted) {
      setState(() {
        _posMs = target;
        _ended = false;
      });
    }
  }

  void _showControlsNow() {
    if (!_showControls && mounted) setState(() => _showControls = true);
    _scheduleHide();
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (_ended) return;
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      final playing = _video?.value.isPlaying ?? false;
      if (playing) setState(() => _showControls = false);
    });
  }

  void _snack(String message, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), action: action),
    );
  }

  Future<void> _minimize() async {
    final video = _video;
    if (video == null || !video.value.isInitialized) {
      Navigator.maybePop(context);
      return;
    }
    final src = current;
    await _saveProgress(force: true);
    _hideTimer?.cancel();
    _closing = true;
    // Stop owning the controller before handing it over: dispose() must not
    // tear down the session the mini-player is about to continue.
    _video = null;
    video.removeListener(_onTick);
    final adopted = MiniPlayer.adopt(
      controller: video,
      title: src.animeTitle.isEmpty ? widget.label : src.animeTitle,
      subtitle: src.episode != null ? 'Episode ${src.episode}' : 'Playing',
      image: src.image,        rebuild: (live) => PlayerScreen(
          url: widget.url,
          label: widget.label,
          localFile: _local,
          playlist: playlist,
          startIndex: index,
          mirrors: widget.mirrors,
          episode: src.episode ?? widget.episode,
          fetchEpisode: widget.fetchEpisode,
          variants: _episodeVariants,
          onOpenAnime: widget.onOpenAnime,
          handoff: live,
          animeId: widget.animeId,
          audio: widget.audio,
          onAudioSwitch: widget.onAudioSwitch,
        ),
    );
    if (!mounted) return;
    if (!adopted) {
      _video = video;
      video.addListener(_onTick);
      _closing = false;
      _snack('That episode could not continue in the background.');
      return;
    }
    Navigator.maybePop(context);
  }

  Future<void> _disposePlayback() async {
    final video = _video;
    _video = null;
    if (video != null) {
      video.removeListener(_onTick);
      try {
        await video.pause();
      } catch (_) {}
      try {
        await video.dispose();
      } catch (_) {}
    }
  }

  String _clock(int ms) {
    if (ms <= 0) return '--:--';
    final total = ms ~/ 1000;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  @override

  Widget build(BuildContext context) {
    if (_fullscreen) {
      // Immersive mode keeps the same player, but gives every available pixel
      // to the video and lets the back gesture exit fullscreen first.
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _toggleFullscreen();
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: _surface(fill: true),
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _surface(),
            if (playlist.length > 1) _episodeStrip(),
            const SizedBox(height: 16),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 26),
                children: [
                  Text(
                    current.animeTitle.isEmpty
                        ? widget.label
                        : current.animeTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    current.episode != null
                        ? 'Episode ${current.episode}'
                        : current.label,
                    style: const TextStyle(
                      color: CamColors.inkDim,
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(children: [
                    if (_canHaveNext)
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _advancing ? null : () => _goNext(),
                          icon: _advancing
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.skip_next_rounded, size: 20),
                          label: const Text('Next episode'),
                        ),
                      ),
                    if (_canHaveNext && playlist.length > 1)
                      const SizedBox(width: 10),
                    if (playlist.length > 1)
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _openEpisodes,
                          icon: const Icon(Icons.list_rounded, size: 20),
                          label: Text('Episodes (${playlist.length})'),
                        ),
                      ),
                  ]),
                  if (_recommended.isNotEmpty || _recsLoading) ...[
                    const SizedBox(height: 26),
                    const Text('More to watch',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 10),
                    _recsSection(),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }


  Widget _surface({bool fill = false}) {
    final v = _video;
    final ready = v != null && v.value.isInitialized;
    final aspect =
        ready && v.value.aspectRatio > 0 ? v.value.aspectRatio : 16 / 9;
    final surface = AspectRatio(
      aspectRatio: aspect,
      child: ColoredBox(
        color: Colors.black,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _loading || _error != null ? null : _toggleControls,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (ready) Center(child: VideoPlayer(v)) else _buildPending(),
              if (ready) _controlsOverlay(),
            ],
          ),
        ),
      ),
    );
    // In fullscreen the video keeps its own aspect ratio inside every available
    // pixel (letterboxed), instead of being locked to the inline strip height.        /// In fullscreen use a letterboxed 9:16 portrait window so the top and
        /// bottom caption scrims stay visible on tall screens (foldables,
        /// landscape+squished, desktop). Keeps the video readable without
        /// swallowing the entire screen. Reduced ratio ensures subtitles are visible.
        if (fill) {
          final maxAspect = 10.0 / 16.0;
          final usedAspect = v?.value.aspectRatio ?? 16.0 / 9.0;
          final windowAspect = usedAspect <= maxAspect
              ? usedAspect
              : maxAspect;
          return Center(
            child: AspectRatio(
              aspectRatio: windowAspect,
              child: surface,
            ),
          );
        }
        return surface;
  }

  Widget _buildPending() {
    if (_error != null) {
      return _PlaybackError(
        message: _error!,
        canRetry: true,
        onRetry: _retry,
      );
    }
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
        const SizedBox(height: 12),
        Text(_attempt.isEmpty ? 'Loading episode…' : _attempt,
            style: const TextStyle(color: CamColors.inkDim, fontSize: 12)),
      ]),
    );
  }

  Widget _controlsOverlay() {
    final total =
        _durMs > 0 ? _durMs : (_video?.value.duration.inMilliseconds ?? 0);
    final pos = (_dragMs ?? _posMs).clamp(0, total == 0 ? 0 : total);
    return AnimatedOpacity(
      opacity: _showControls ? 1 : 0,
      duration: const Duration(milliseconds: 180),
      child: IgnorePointer(
        ignoring: !_showControls,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Readability scrims, top and bottom.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black54, Colors.transparent],
                  stops: [0, 0.35],
                ),
              ),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black87, Colors.transparent],
                  stops: [0, 0.55],
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Row(children: [
                IconButton(
                  tooltip: 'Close player',
                  onPressed: () => Navigator.maybePop(context),
                  icon: const Icon(Icons.arrow_back_ios_new_rounded,
                      color: Colors.white, size: 19),
                ),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        current.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700),
                      ),
                      if (widget.audio != null) ...[
                        const SizedBox(width: 8),
                        _AudioSwitchButton(
                          currentAudio: _currentAudio,
                          onSwitch: _switchAudio,
                          enabled: !_switching,
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  tooltip: _fullscreen ? 'Exit fullscreen' : 'Fullscreen',
                  onPressed: _toggleFullscreen,
                  icon: Icon(
                      _fullscreen
                          ? Icons.fullscreen_exit_rounded
                          : Icons.fullscreen_rounded,
                      color: Colors.white,
                      size: 21),
                ),
                IconButton(
                  tooltip: 'Play in mini-player',
                  onPressed: _minimize,
                  icon: const Icon(Icons.picture_in_picture_alt_rounded,
                      color: Colors.white, size: 20),
                ),
              ]),
            ),
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _roundButton(
                    icon: Icons.replay_10_rounded,
                    label: 'Back 10 seconds',
                    onTap: () => _skip(-10),
                  ),
                  const SizedBox(width: 18),
                  _roundButton(
                    icon: _ended
                        ? Icons.replay_rounded
                        : (_video?.value.isPlaying ?? false)
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                    label: _ended
                        ? 'Replay episode'
                        : (_video?.value.isPlaying ?? false)
                            ? 'Pause'
                            : 'Play',
                    size: 58,
                    onTap: _togglePlay,
                  ),
                  const SizedBox(width: 18),
                  _roundButton(
                    icon: Icons.forward_10_rounded,
                    label: 'Forward 10 seconds',
                    onTap: () => _skip(10),
                  ),
                  if (_canHaveNext || _advancing) ...[
                    const SizedBox(width: 18),
                    _roundButton(
                      icon: Icons.skip_next_rounded,
                      label: 'Next episode',
                      busy: _advancing,
                      onTap: _advancing ? null : () => _goNext(),
                    ),
                  ],
                ],
              ),
            ),
            if (_ended)
              Positioned(
                left: 18,
                right: 18,
                bottom: 74,
                child: _ended ? _endCard() : const SizedBox.shrink(),
              ),
            Positioned(
              left: 8,
              right: 8,
              bottom: 0,
              child: Row(children: [
                Text(_clock(pos),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600)),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2.5,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 16),
                    ),
                    child: Slider(
                      value: pos
                          .toDouble()
                          .clamp(0, total == 0 ? 1 : total.toDouble()),
                      max: total == 0 ? 1 : total.toDouble(),
                      activeColor: CamColors.accent,
                      inactiveColor: Colors.white24,
                      onChanged: (value) {
                        setState(() => _dragMs = value.round());
                        _hideTimer?.cancel();
                      },
                      onChangeEnd: (value) async {
                        await _seekTo(value.round());
                        if (mounted) setState(() => _dragMs = null);
                        _scheduleHide();
                      },
                    ),
                  ),
                ),
                Text(_clock(total),
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 11.5)),
                IconButton(
                  tooltip: 'Playback settings',
                  onPressed: _openSettings,
                  icon: const Icon(Icons.tune_rounded,
                      color: Colors.white, size: 20),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _endCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(children: [
        Expanded(
          child: Text(
            _canHaveNext
                ? 'Up next · Episode ${(current.episode ?? 0) + 1}'
                : 'You finished this episode.',
            style: const TextStyle(
                color: Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.w700),
          ),
        ),
        if (_canHaveNext)
          FilledButton(
            onPressed: _advancing ? null : () => _goNext(),
            child: const Text('Play next'),
          )
        else
          TextButton(
            onPressed: _togglePlay,
            child: const Text('Replay'),
          ),
      ]),
    );
  }

  Widget _roundButton({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    double size = 46,
    bool busy = false,
  }) {
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: InkResponse(
          onTap: onTap,
          radius: size * 0.7,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withValues(alpha: 0.42),
              border: Border.all(color: Colors.white24),
            ),
            alignment: Alignment.center,
            child: busy
                ? SizedBox(
                    width: size * 0.4,
                    height: size * 0.4,
                    child: const CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : Icon(icon, color: Colors.white, size: size * 0.52),
          ),
        ),
      ),
    );
  }

  Future<void> _applyBrightness(double value) async {
    try {
      await _playerChannel.invokeMethod('brightness', {'value': value});
    } catch (_) {
      // Platform without the bridge (tests/desktop): in-app overlay is still
      // usable, so this is not an error worth interrupting playback for.
    }
  }

  Future<void> _savePlaybackPrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble('player_volume', _volume);
    await p.setDouble('player_brightness', _brightness);
  }

  Future<void> _toggleFullscreen() async {
    final next = !_fullscreen;
    if (mounted) setState(() => _fullscreen = next);
    try {
      if (next) {
        await SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } else {
        await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
    } catch (_) {}
    _scheduleHide();
  }

  Widget _episodeStrip() {
    return SizedBox(
      height: 50,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 7, 12, 5),
        itemCount: playlist.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final episode = playlist[i].episode ?? (i + 1);
          return ChoiceChip(
            label: Text('EP $episode'),
            selected: i == index,
            visualDensity: VisualDensity.compact,
            labelStyle:
                const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
            onSelected: (_) {
              if (i != index) _goTo(i);
            },
          );
        },
      ),
    );
  }

  Future<void> _openSettings() async {
    _hideTimer?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: CamColors.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_qualities.length > 1 && !_local) ...[
                    const Text('Video quality',
                        style: TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final height in _qualities)
                        ChoiceChip(
                          label: Text('${height}p'),
                          selected: _activeHeight == height,
                          onSelected: (_) {
                            Navigator.pop(ctx);
                            _selectQuality(height);
                          },
                        ),
                    ]),
                    const Text(
                        'Only resolutions this source publishes are listed. '
                        'HLS adapts within the provider\u2019s real renditions.',
                        style:
                            TextStyle(color: CamColors.inkDim, fontSize: 10.5)),
                    const SizedBox(height: 18),
                  ],
                  const Text('Volume',
                      style: TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.w800)),
                  Row(children: [
                    Icon(
                        _volume == 0
                            ? Icons.volume_off_rounded
                            : Icons.volume_up_rounded,
                        size: 18,
                        color: CamColors.inkDim),
                    Expanded(
                      child: Slider(
                        value: _volume,
                        activeColor: CamColors.accent,
                        onChanged: (value) {
                          setSheet(() => _volume = value);
                          setState(() => _volume = value);
                          _video?.setVolume(value);
                        },
                        onChangeEnd: (_) => _savePlaybackPrefs(),
                      ),
                    ),
                    Text('${(_volume * 100).round()}%',
                        style: const TextStyle(
                            fontSize: 11, color: CamColors.inkDim)),
                  ]),
                  const Text('Brightness',
                      style: TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.w800)),
                  Row(children: [
                    const Icon(Icons.brightness_6_rounded,
                        size: 18, color: CamColors.inkDim),
                    Expanded(
                      child: Slider(
                        value: _brightness,
                        min: 0.15,
                        activeColor: CamColors.accent,
                        onChanged: (value) {
                          setSheet(() => _brightness = value);
                          setState(() => _brightness = value);
                          unawaited(_applyBrightness(value));
                        },
                        onChangeEnd: (_) => _savePlaybackPrefs(),
                      ),
                    ),
                    Text('${(_brightness * 100).round()}%',
                        style: const TextStyle(
                            fontSize: 11, color: CamColors.inkDim)),
                  ]),
                  const SizedBox(height: 8),
                  const Text('Playback speed',
                      style: TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final speed in const [0.75, 1.0, 1.25, 1.5, 2.0])
                      ChoiceChip(
                        label: Text(speed == 1.0 ? '1x' : '${speed}x'),
                        selected: _speed == speed,
                        onSelected: (_) async {
                          setSheet(() => _speed = speed);
                          _applySpeed();
                          final p = await SharedPreferences.getInstance();
                          await p.setDouble('player_speed', speed);
                        },
                      ),
                  ]),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Auto play next episode',
                        style: TextStyle(fontSize: 13)),
                    value: _autoplayNext,
                    onChanged: (value) async {
                      setSheet(() => _autoplayNext = value);
                      if (mounted) setState(() => _autoplayNext = value);
                      final p = await SharedPreferences.getInstance();
                      await p.setBool('app_autoplay', value);
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Auto skip intro',
                        style: TextStyle(fontSize: 13)),
                    subtitle: const Text('Jump past the first 90 seconds',
                        style: TextStyle(fontSize: 11)),
                    value: _autoSkipIntro,
                    onChanged: (value) async {
                      setSheet(() => _autoSkipIntro = value);
                      if (mounted) setState(() => _autoSkipIntro = value);
                      final p = await SharedPreferences.getInstance();
                      await p.setBool('player_skip_intro', value);
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Auto skip outro to next episode',
                        style: TextStyle(fontSize: 13)),
                    subtitle: const Text(
                        'Starts the next episode near the ending',
                        style: TextStyle(fontSize: 11)),
                    value: _autoSkipOutro,
                    onChanged: (value) async {
                      setSheet(() => _autoSkipOutro = value);
                      if (mounted) setState(() => _autoSkipOutro = value);
                      final p = await SharedPreferences.getInstance();
                      await p.setBool('player_skip_outro', value);
                    },
                  ),
                  if (playlist.length > 1) ...[
                    const Divider(),
                    Text('Episodes (${playlist.length})',
                        style: const TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w800)),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 160),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: playlist.length,
                        itemBuilder: (_, i) => ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            i == index
                                ? Icons.graphic_eq_rounded
                                : Icons.play_arrow_rounded,
                            size: 18,
                            color: i == index ? CamColors.accent : null,
                          ),
                          title: Text(playlist[i].label,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: () {
                            Navigator.pop(ctx);
                            if (i != index) _goTo(i);
                          },
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
    _scheduleHide();
  }

  Future<void> _openEpisodes() async {
    if (playlist.length <= 1) return;
    _hideTimer?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: CamColors.surface,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: playlist.length,
          itemBuilder: (_, i) => ListTile(
            leading: Icon(
              i == index ? Icons.graphic_eq_rounded : Icons.play_arrow_rounded,
              color: i == index ? CamColors.accent : null,
            ),
            title: Text(playlist[i].label,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            selected: i == index,
            onTap: () {
              Navigator.pop(ctx);
              if (i != index) _goTo(i);
            },
          ),
        ),
      ),
    );
    _scheduleHide();
  }

  Widget _recsSection() {
    if (_recsLoading && _recommended.isEmpty) {
      return const CamSkeleton(height: 110, radius: 16);
    }
    return SizedBox(
      height: 178,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
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
              await _startRecommendation(id, title);
            },
            child: SizedBox(
              width: 104,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: AspectRatio(
                      aspectRatio: 2 / 2.6,
                      child: image.isEmpty
                          ? const ColoredBox(
                              color: CamColors.surfaceAlt,
                              child: Icon(Icons.movie_outlined,
                                  color: CamColors.inkDim),
                            )
                          : Image.network(
                              image,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const ColoredBox(
                                color: CamColors.surfaceAlt,
                                child: Icon(Icons.movie_outlined,
                                    color: CamColors.inkDim),
                              ),
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
    );
  }

  Future<void> _startRecommendation(String animeId, String title) async {
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
        _snack('No playable server for that anime yet.');
        return;
      }
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            url: urls.first,
            mirrors: urls.skip(1).toList(),
            label: '$title — Ep 1 (English SUB)',
            onOpenAnime: widget.onOpenAnime,
            animeId: widget.animeId,
            audio: widget.audio,
            onAudioSwitch: widget.onAudioSwitch,
          ),
        ),
      );
    } catch (_) {
      _snack('Could not reach the server for that anime.');
    }
  }
}

class _AudioSwitchButton extends StatelessWidget {
  final String currentAudio;
  final void Function(String) onSwitch;
  final bool enabled;
  const _AudioSwitchButton({
    required this.currentAudio,
    required this.onSwitch,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    final other = currentAudio == 'sub' ? 'dub' : 'sub';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? () => onSwitch(other) : null,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: enabled
                ? (currentAudio == 'dub'
                    ? const Color(0xFFFF5E62)
                    : const Color(0xFF34d399).withAlpha(170))
                : const Color(0xFF444854),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: enabled
                  ? (currentAudio == 'dub'
                      ? const Color(0xFFFF5E62)
                      : const Color(0xFF34d399))
                  : const Color(0xFF3a3e47),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                currentAudio == 'sub'
                    ? Icons.closed_caption_rounded
                    : Icons.headphones_rounded,
                size: 13,
                color: Colors.white,
              ),
              const SizedBox(width: 5),
              Tooltip(
                message: currentAudio == 'sub' ? 'English subtitles (SUB)' : 'English dub (DUB)',
                child: Text(
                  currentAudio.toUpperCase(),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800),
                ),
              ),
              if (enabled) ...
                [
                  const SizedBox(width: 4),
                  Icon(
                    Icons.west_rounded,
                    size: 12,
                    color: Colors.white70,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    other.toUpperCase(),
                    style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.w700),
                  ),
                ],
            ],
          ),
        ),
      ),
    );
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
