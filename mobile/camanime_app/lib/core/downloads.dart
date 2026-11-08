import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_notifications.dart';
import 'device_storage.dart';

/// Lifecycle of one offline episode.
enum DownloadStage {
  queued,
  downloading,
  waitingNetwork,
  paused,
  completed,
  failed,
}

extension DownloadStageX on DownloadStage {
  bool get isActive =>
      this == DownloadStage.queued ||
      this == DownloadStage.downloading ||
      this == DownloadStage.waitingNetwork;

  String get label => switch (this) {
        DownloadStage.queued => 'Queued',
        DownloadStage.downloading => 'Downloading',
        DownloadStage.waitingNetwork => 'Waiting for internet',
        DownloadStage.paused => 'Paused',
        DownloadStage.completed => 'Ready offline',
        DownloadStage.failed => 'Failed',
      };
}

/// A single episode download that survives app restarts and connectivity
/// drops. Bytes already written to the `.part` file are never thrown away:
/// a resume issues an HTTP Range request and appends from that offset.
class DownloadTask {
  final String id;
  final int animeId;
  final String animeTitle;
  final int episode;
  final String audio;
  final String sourceUrl;
  final String fileName;
  final String image;
  String? localName;

  /// "Spring 2013" style label; library folders group by anime + season.
  final String season;

  /// Advertised pixel height of the saved file (0 when the provider is vague).
  final int height;

  /// Episode runtime in minutes from the catalogue (0 when unknown), so the
  /// Library can show real play time instead of just a file size.
  final int durationMinutes;

  /// Set the moment the file is complete, so the Library can say exactly when
  /// the episode became watchable offline.
  int completedAt;

  /// Location of the exported public copy (`Download/CamAnime/...`), if any.
  String? devicePath;

  int received;
  int total;

  /// True when [total] is a sampled estimate from the stitcher rather than a
  /// byte-exact length: progress is real, but only the end of the stream can
  /// declare the transfer complete.
  bool estimated;
  DownloadStage stage;
  String error;
  int updatedAt;

  DownloadTask({
    required this.id,
    required this.animeId,
    required this.animeTitle,
    required this.episode,
    required this.audio,
    required this.sourceUrl,
    required this.fileName,
    this.image = '',
    this.localName,
    this.season = '',
    this.height = 0,
    this.durationMinutes = 0,
    this.completedAt = 0,
    this.devicePath,
    this.received = 0,
    this.total = 0,
    this.estimated = false,
    this.stage = DownloadStage.queued,
    this.error = '',
    this.updatedAt = 0,
  });

  double? get progress => total > 0 ? (received / total).clamp(0.0, 1.0) : null;

  String get displayTitle => '$animeTitle · Ep $episode';

  String get qualityLabel => height > 0 ? '${height}p' : 'Auto';

  String get durationLabel {
    if (durationMinutes <= 0) return '';
    if (durationMinutes < 60) return '$durationMinutes min';
    final h = durationMinutes ~/ 60;
    final m = durationMinutes % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  /// "Completed · 2.4 GB · 12:41" for the Library, empty while still running.
  String get completedLabel {
    if (stage != DownloadStage.completed) return '';
    final at = completedAt > 0 ? DateTime.fromMillisecondsSinceEpoch(completedAt) : null;
    final when = at == null
        ? ''
        : ' · ${at.day.toString().padLeft(2, '0')}/${at.month.toString().padLeft(2, '0')} '
            '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    return 'Completed$when';
  }

  bool get isPlayablePartially => received > 1024 * 1024;

  Map<String, dynamic> toJson() => {
        'id': id,
        'anime_id': animeId,
        'anime_title': animeTitle,
        'episode': episode,
        'audio': audio,
        'source_url': sourceUrl,
        'file_name': fileName,
        'image': image,
        'local_name': localName,
        'season': season,
        'duration_min': durationMinutes,
        'height': height,
        'completed_at': completedAt,
        'device_path': devicePath,
        'received': received,
        'total': total,
        'estimated': estimated,
        'stage': stage.name,
        'error': error,
        'updated_at': updatedAt,
      };

  static DownloadTask fromJson(Map<String, dynamic> json) => DownloadTask(
        id: (json['id'] ?? '').toString(),
        animeId: int.tryParse('${json['anime_id'] ?? 0}') ?? 0,
        animeTitle: (json['anime_title'] ?? '').toString(),
        episode: int.tryParse('${json['episode'] ?? 0}') ?? 0,
        audio: (json['audio'] ?? 'sub').toString(),
        sourceUrl: (json['source_url'] ?? '').toString(),
        fileName: (json['file_name'] ?? 'episode.mp4').toString(),
        image: (json['image'] ?? '').toString(),
        localName: json['local_name']?.toString(),
        season: (json['season'] ?? '').toString(),
        durationMinutes: int.tryParse('${json['duration_min'] ?? 0}') ?? 0,
        height: int.tryParse('${json['height'] ?? 0}') ?? 0,
        completedAt: int.tryParse('${json['completed_at'] ?? 0}') ?? 0,
        devicePath: json['device_path']?.toString(),
        received: int.tryParse('${json['received'] ?? 0}') ?? 0,
        total: int.tryParse('${json['total'] ?? 0}') ?? 0,
        estimated: json['estimated'] == true,
        stage: DownloadStage.values.firstWhere(
          (e) => e.name == json['stage'],
          orElse: () => DownloadStage.queued,
        ),
        error: (json['error'] ?? '').toString(),
        updatedAt: int.tryParse('${json['updated_at'] ?? 0}') ?? 0,
      );
}

/// Keeps the Flutter process alive (and visible in the notification shade)
/// while episodes download. No-op on platforms without the Android service.
class BackgroundKeepAlive {
  static const _channel = MethodChannel('camanime/keepalive');
  static bool _running = false;

  static Future<void> set(bool on) async {
    if (_running == on) return;
    _running = on;
    try {
      await _channel.invokeMethod<String>(on ? 'start' : 'stop');
    } catch (_) {
      // Desktop/web or a platform without the service — downloads still run.
    }
  }
}

/// One shelf in the Library: every downloaded episode of one anime season.
///
/// Season grouping is what keeps a 100-episode shonen from burying the rest of
/// the library: episodes of the same season always land in the same folder.
class DownloadFolder {
  final String animeTitle;
  final String season;
  final List<DownloadTask> tasks;

  const DownloadFolder({
    required this.animeTitle,
    required this.season,
    required this.tasks,
  });

  String get key => '$animeTitle|$season';
  String get title => animeTitle;
  String get subtitle => season.isEmpty ? 'All episodes' : season;
  int get bytes => tasks.fold(0, (sum, t) => sum + max(t.total, t.received));
  String get cover =>
      tasks.firstWhere((t) => t.image.isNotEmpty, orElse: () => tasks.first).image;
  List<int> get episodes => tasks.map((t) => t.episode).toList()..sort();
  bool get allExported => tasks.every((t) => (t.devicePath ?? '').isNotEmpty);
}

/// Persistent, resumable episode download queue.
///
/// Design:
///  * the queue and its byte offsets live in `camanime_downloads/queue.json`,
///    so nothing is lost when the app is killed;
///  * writes go to `<id>.part` and become `<title> - Ep N.mp4` only after a
///    complete, size-verified transfer;
///  * the .part file is exposed to the player, so an episode can be watched
///    while the rest keeps downloading;
///  * failures caused by connectivity move the task to `waitingNetwork` and
///    a retry timer re-issues Range requests until the network is back.
class DownloadManager extends ChangeNotifier {
  DownloadManager._();
  static final DownloadManager instance = DownloadManager._();

  final Map<String, DownloadTask> _tasks = {};
  final Set<String> _running = {};
  final Set<String> _pausing = {};
  final Map<String, http.Client> _clients = {};

  Directory? _root;
  Directory? _media;
  bool _ready = false;
  bool get ready => _ready;

  Timer? _retryTimer;

  /// Grows while a server keeps failing, so a dead provider is not hammered
  /// every few seconds on a metered connection.
  int _retryDelaySeconds = 8;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  int _concurrency = 2;
  bool _autoResume = true;
  bool get autoResume => _autoResume;
  int get concurrency => _concurrency;

  /// Supplied by the app so downloads carry the same auth headers as the API.
  Future<Map<String, String>> Function()? headersProvider;

  /// Test-only switch: lets the resume test run against a loopback HTTP
  /// server. Production downloads still require HTTPS.
  @visibleForTesting
  bool allowInsecureForTests = false;

  /// Test-only HTTP client injection (widget-test bindings block real IO).
  @visibleForTesting
  http.Client Function()? clientFactory;

  @visibleForTesting
  Future<void> resetForTests() async {
    _retryTimer?.cancel();
    _tasks.clear();
    _running.clear();
    _pausing.clear();
    _clients.clear();
    _root = null;
    _media = null;
    _ready = false;
    _speedBytesPerSecond = 0;
  }

  double _speedBytesPerSecond = 0;
  double get speedBytesPerSecond => _speedBytesPerSecond;
  int _speedSampleBytes = 0;
  DateTime _speedSampleAt = DateTime.now();

  List<DownloadTask> get tasks {
    final list = _tasks.values.toList();
    list.sort((a, b) {
      final aDone = a.stage == DownloadStage.completed ? 1 : 0;
      final bDone = b.stage == DownloadStage.completed ? 1 : 0;
      if (aDone != bDone) return aDone - bDone;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return list;
  }

  List<DownloadTask> get active => _tasks.values
      .where((t) =>
          t.stage == DownloadStage.downloading ||
          t.stage == DownloadStage.queued ||
          t.stage == DownloadStage.waitingNetwork)
      .toList()
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  List<DownloadTask> get paused => _tasks.values
      .where((t) =>
          t.stage == DownloadStage.paused || t.stage == DownloadStage.failed)
      .toList();

  List<DownloadTask> get completed =>
      _tasks.values.where((t) => t.stage == DownloadStage.completed).toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  /// Completed episodes folded into anime + season folders, newest first.
  List<DownloadFolder> get folders {
    final groups = <String, List<DownloadTask>>{};
    for (final task in completed) {
      final season = task.season.trim();
      groups.putIfAbsent('${task.animeTitle}|$season', () => []).add(task);
    }
    final out = <DownloadFolder>[];
    groups.forEach((key, tasks) {
      final first = tasks.first;
      tasks.sort((a, b) => a.episode.compareTo(b.episode));
      out.add(DownloadFolder(
        animeTitle: first.animeTitle,
        season: first.season.trim(),
        tasks: tasks,
      ));
    });
    out.sort((a, b) => b.tasks.first.updatedAt.compareTo(a.tasks.first.updatedAt));
    return out;
  }

  int get activeCount => active.length;
  int get readyCount => completed.length;
  bool get isIdle => active.isEmpty && _running.isEmpty;

  int get bytesUsed => _tasks.values
      .where((t) => t.stage == DownloadStage.completed)
      .fold(0, (sum, t) => sum + max(t.total, t.received));

  int get bytesReserved => _tasks.values
      .where((t) => t.stage != DownloadStage.completed)
      .fold(0, (sum, t) => sum + t.received);

  DownloadTask? taskFor(int animeId, int episode) {
    for (final t in _tasks.values) {
      if (t.animeId == animeId && t.episode == episode) return t;
    }
    return null;
  }

  DownloadTask? byId(String id) => _tasks[id];

  File? completedFile(DownloadTask task) {
    final name = task.localName;
    if (name == null || _media == null) return null;
    final file = File('${_media!.path}/$name');
    return file.existsSync() ? file : null;
  }

  File? partFile(DownloadTask task) {
    if (_media == null) return null;
    final file = File('${_media!.path}/${task.id}.part');
    return file.existsSync() ? file : null;
  }

  /// File the player can open right now — complete, or a partially written
  /// file once enough of the episode is on disk to start watching.
  File? playableFile(DownloadTask task) {
    final done = completedFile(task);
    if (done != null) return done;
    if (task.isPlayablePartially) return partFile(task);
    return null;
  }

  bool isPartial(DownloadTask task) =>
      task.stage != DownloadStage.completed &&
      task.isPlayablePartially &&
      partFile(task) != null;

  Future<void> init() async {
    if (_ready) return;
    try {
      final support = await getApplicationSupportDirectory();
      _root = Directory('${support.path}/camanime_downloads');
      _media = Directory('${_root!.path}/media');
      await _media!.create(recursive: true);
      try {
        final prefs = await SharedPreferences.getInstance();
        _concurrency = (prefs.getInt('download_concurrency') ?? 2).clamp(1, 3);
        _autoResume = prefs.getBool('download_auto_resume') ?? true;
      } catch (_) {
        // Preferences unavailable (tests / locked profile): defaults apply.
      }
      await _loadQueue();
      await _importLegacyLibrary(support);
      await refresh();
      _ready = true;
      notifyListeners();
      if (_autoResume) _pump();
    } catch (_) {
      // Storage unavailable (e.g. widget tests) — the UI stays functional and
      // shows an empty library instead of crashing.
      _ready = false;
    }
  }

  Future<void> _loadQueue() async {
    final file = File('${_root!.path}/queue.json');
    if (!await file.exists()) return;
    try {
      final rows = json.decode(await file.readAsString());
      if (rows is! List) return;
      for (final raw in rows) {
        if (raw is! Map) continue;
        final task = DownloadTask.fromJson(raw.cast<String, dynamic>());
        if (task.id.isEmpty || task.fileName.isEmpty) continue;
        if (task.sourceUrl.isEmpty && task.localName == null) continue;
        // A task that claimed completion but has no file is retried.
        if (task.stage == DownloadStage.completed &&
            !_fileExists(task.localName)) {
          task.stage = task.sourceUrl.isEmpty
              ? DownloadStage.failed
              : DownloadStage.queued;
          task.received = 0;
          task.error = 'Saved file is missing.';
        }
        _tasks[task.id] = task;
      }
    } catch (_) {
      // A damaged queue must never block a fresh start; files are rescanned.
    }
  }

  bool _fileExists(String? name) =>
      name != null &&
      _media != null &&
      File('${_media!.path}/$name').existsSync();

  /// Episodes downloaded by the previous app version already live in the
  /// legacy library folder. Surface them as completed tasks instead of
  /// hiding the user's existing offline episodes.
  Future<void> _importLegacyLibrary(Directory support) async {
    final legacy = Directory('${support.path}/camanime_library');
    if (!await legacy.exists()) return;
    Map<String, dynamic> meta = {};
    final manifest = File('${legacy.path}/library.json');
    if (await manifest.exists()) {
      try {
        final rows = json.decode(await manifest.readAsString());
        if (rows is List) {
          for (final raw in rows) {
            if (raw is Map) {
              meta[(raw['file'] ?? '').toString()] = raw;
            }
          }
        }
      } catch (_) {}
    }
    await for (final entity in legacy.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.toLowerCase().endsWith('.mp4') &&
          !name.toLowerCase().endsWith('.m4v')) {
        continue;
      }
      final size = await entity.length();
      if (size < 1024) continue;
      final id =
          'legacy-${sha256.convert(utf8.encode(entity.path)).toString().substring(0, 16)}';
      if (_tasks.containsKey(id)) continue;
      final row = meta[name];
      final title = (row?['title'] ?? name).toString();
      final ep = int.tryParse('${row?['episode'] ?? 0}') ?? 0;
      _tasks[id] = DownloadTask(
        id: id,
        animeId: int.tryParse('${row?['anime_id'] ?? 0}') ?? 0,
        animeTitle: ep > 0
            ? title.replaceFirst(RegExp(r'\s*-\s*Ep\s*\d+$'), '')
            : title,
        episode: ep,
        audio: (row?['audio'] ?? 'sub').toString(),
        sourceUrl: '',
        fileName: name,
        localName: entity.path,
        received: size,
        total: size,
        stage: DownloadStage.completed,
        updatedAt: DateTime.tryParse('${row?['completed_at'] ?? ''}')
                ?.millisecondsSinceEpoch ??
            (await entity.lastModified()).millisecondsSinceEpoch,
      );
    }
  }

  Future<void> refresh() async {
    if (_root == null) return;
    for (final task in _tasks.values.toList()) {
      if (task.stage == DownloadStage.completed) {
        final file = completedFile(task);
        if (file == null) {
          task.stage = DownloadStage.failed;
          task.error = 'Saved file is missing.';
          task.received = 0;
        } else {
          task.total = await file.length();
          task.received = task.total;
        }
        continue;
      }
      final part = partFile(task);
      if (part != null) {
        task.received = await part.length();
        if (!task.estimated && task.total > 0 && task.received >= task.total) {
          await _finalize(task);
        }
      }
    }
    _safeNotify();
  }

  Future<DownloadTask> enqueue({
    required String animeTitle,
    required int animeId,
    required int episode,
    required String audio,
    required String url,
    String image = '',
    String season = '',
    int height = 0,
    int durationMinutes = 0,
  }) async {
    await init();
    if (_root == null) throw const FileSystemException('Storage unavailable');
    final secure = url.startsWith('https://');
    final loopbackTest =
        allowInsecureForTests && url.startsWith('http://127.0.0.1');
    if (!secure && !loopbackTest) {
      throw const HttpException('Episodes download over secure HTTPS only.');
    }
    final id = sha256
        .convert(utf8.encode('$animeId|$episode|$audio|$url'))
        .toString()
        .substring(0, 20);
    final existing = _tasks[id];
    if (existing != null) {
      if (existing.stage == DownloadStage.completed) return existing;
      if (existing.stage == DownloadStage.failed ||
          existing.stage == DownloadStage.paused) {
        await resume(id);
      }
      return existing;
    }
    final safeTitle = _safeName('$animeTitle - Ep $episode');
    final task = DownloadTask(
      id: id,
      animeId: animeId,
      animeTitle: animeTitle,
      episode: episode,
      audio: audio,
      sourceUrl: url,
      fileName: '$safeTitle.${_extensionFor(url)}',
      image: image,
      season: season.trim(),
      height: height,
      durationMinutes: durationMinutes,
      total: 0,
      stage: DownloadStage.queued,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _tasks[id] = task;
    await _persist();
    _safeNotify();
    _pump();
    return task;
  }

  Future<void> pause(String id) async {
    final task = _tasks[id];
    if (task == null || task.stage == DownloadStage.completed) return;
    _pausing.add(id);
    task.stage = DownloadStage.paused;
    task.error = '';
    task.updatedAt = DateTime.now().millisecondsSinceEpoch;
    _clients[id]?.close();
    await _persist();
    _safeNotify();
    _syncKeepAlive();
  }

  Future<void> resume(String id) async {
    final task = _tasks[id];
    if (task == null || task.stage == DownloadStage.completed) return;
    if (task.sourceUrl.isEmpty) {
      task.stage = DownloadStage.failed;
      task.error = 'No downloadable source was saved for this episode.';
      _safeNotify();
      return;
    }
    _pausing.remove(id);
    task.stage = DownloadStage.queued;
    task.error = '';
    task.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await _persist();
    _safeNotify();
    _pump();
  }

  Future<void> pauseAll() async {
    for (final task in _tasks.values.toList()) {
      if (task.stage.isActive) await pause(task.id);
    }
  }

  Future<void> resumeAll() async {
    for (final task in _tasks.values.toList()) {
      if (task.stage == DownloadStage.paused ||
          task.stage == DownloadStage.waitingNetwork ||
          task.stage == DownloadStage.failed) {
        await resume(task.id);
      }
    }
  }

  /// Removes the task and everything it wrote. Completed files are deleted
  /// too — this is the Library's delete action.
  Future<void> remove(String id) async {
    final task = _tasks.remove(id);
    _pausing.remove(id);
    _clients[id]?.close();
    if (task == null) return;
    try {
      final part = partFile(task);
      if (part != null) await part.delete();
      final done = completedFile(task);
      if (done != null) await done.delete();
      final local = task.localName;
      if (local != null && local.endsWith('.mp4')) {
        final file = File(local);
        if (await file.exists()) await file.delete();
      }
    } catch (_) {}
    await _persist();
    _safeNotify();
    _syncKeepAlive();
    _pump();
  }

  /// Explicit cancel: stops the transfer and deletes only the partial bytes,
  /// so the same episode can be downloaded again from scratch.
  Future<void> cancel(String id) => remove(id);

  Future<void> clearCompleted() async {
    for (final task in completed.toList()) {
      await remove(task.id);
    }
  }

  Future<void> setAutoResume(bool value) async {
    _autoResume = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('download_auto_resume', value);
    if (value) {
      _pump();
    } else {
      _retryTimer?.cancel();
    }
    notifyListeners();
  }

  Future<void> setConcurrency(int value) async {
    _concurrency = value.clamp(1, 4);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('download_concurrency', _concurrency);
    notifyListeners();
    _pump();
  }

  /// Called when the app returns to the foreground or the OS reports a
  /// network change: queued and waiting tasks get another chance immediately.
  Future<void> kick() async {
    if (!_autoResume) return;
    _retryTimer?.cancel();
    _retryDelaySeconds = 8;
    for (final task in _tasks.values.toList()) {
      if (task.stage == DownloadStage.waitingNetwork ||
          task.stage == DownloadStage.failed) {
        task.stage = DownloadStage.queued;
        task.error = '';
      }
    }
    _pump();
  }

  void _pump() {
    if (!_ready || _root == null) return;
    final pending = _tasks.values
        .where((t) => t.stage == DownloadStage.queued)
        .toList()
      ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    for (final task in pending) {
      if (_running.length >= _concurrency) break;
      if (_running.contains(task.id)) continue;
      unawaited(_download(task));
    }
    _syncKeepAlive();
    final waiting = _tasks.values.any((t) =>
        t.stage == DownloadStage.queued ||
        t.stage == DownloadStage.waitingNetwork);
    if (waiting && _autoResume && _running.isEmpty) {
      _retryTimer?.cancel();
      final delay = Duration(seconds: _retryDelaySeconds);
      _retryTimer = Timer(delay, () {
        _retryDelaySeconds = (_retryDelaySeconds * 2).clamp(8, 60).toInt();
        for (final task in _tasks.values) {
          if (task.stage == DownloadStage.waitingNetwork) {
            task.stage = DownloadStage.queued;
          }
        }
        _pump();
      });
    }
  }

  /// Pooled HTTP client with real socket timeouts: a stalled provider is
  /// abandoned instead of hanging the queue, and a fast link (Starlink, 5G,
  /// fibre) never waits on a fresh TLS handshake for every request.
  http.Client _tunedClient() =>
      clientFactory?.call() ??
          IOClient(HttpClient()
            ..connectionTimeout = const Duration(seconds: 15)
            ..idleTimeout = const Duration(seconds: 25)
            ..autoUncompress = false);

  Future<void> _download(DownloadTask task) async {
    _running.add(task.id);
    task.stage = DownloadStage.downloading;
    task.error = '';
    task.updatedAt = DateTime.now().millisecondsSinceEpoch;
    _safeNotify();

    final part = File('${_media!.path}/${task.id}.part');
    RandomAccessFile? raf;
    http.Client? client;
    var received = 0;
    try {
      await part.parent.create(recursive: true);
      var offset = await part.exists() ? await part.length() : 0;
      if (!task.estimated && task.total > 0 && offset >= task.total) {
        await _finalize(task);
        return;
      }
      client = _tunedClient();
      _clients[task.id] = client;
      final headers = <String, String>{
        'Accept': 'video/*,application/octet-stream',
        // Ask for the raw bytes: a transparently gzipped transfer corrupts
        // Range resume offsets and hides the real Content-Length.
        'Accept-Encoding': 'identity',
        if (offset > 0) 'Range': 'bytes=$offset-',
        ...?await headersProvider?.call(),
      };
      final request = http.Request('GET', Uri.parse(task.sourceUrl))
        ..headers.addAll(headers)
        ..followRedirects = true;
      final response =
          await client.send(request).timeout(const Duration(seconds: 45));
      if (response.statusCode != 200 && response.statusCode != 206) {
        await response.stream.drain<void>();
        throw HttpException('Server returned ${response.statusCode}');
      }
      final contentType =
          (response.headers['content-type'] ?? '').toLowerCase();
      if (contentType.contains('text/html') ||
          contentType.contains('json') ||
          contentType.contains('mpegurl')) {
        await response.stream.drain<void>();
        throw const HttpException(
            'This source is a page or HLS playlist, not a downloadable video.');
      }
      // A server that ignores Range restarts the file; truncate first.
      if (offset > 0 && response.statusCode == 200) {
        await part.writeAsBytes(const [], flush: true);
        offset = 0;
      }
      // A live stream reset the backoff: the server is talking to us again.
      _retryDelaySeconds = 8;
      final chunkLength = response.contentLength ?? 0;
      final estimate =
          int.tryParse(response.headers['x-total-bytes'] ?? '') ?? 0;
      if (response.statusCode == 206) {
        final total = _totalFromContentRange(response.headers['content-range']);
        if (total > 0) {
          task.total = total;
          task.estimated = false;
        }
        if (chunkLength > 0 && task.total == 0) {
          task.total = offset + chunkLength;
          task.estimated = false;
        }
      } else if (chunkLength > 0) {
        task.total = chunkLength;
        task.estimated = false;
      } else if (estimate > 0) {
        // A stitched HLS episode: the server cannot know the exact size before
        // streaming it, so the bar runs on its estimate and the stream itself
        // decides when the file is done.
        task.total = estimate;
        // The stitcher says whether it summed every segment (1) or sampled
        // them (0); only a sample needs the stream to decide completion.
        task.estimated = response.headers['x-total-exact'] != '1';
      }
      raf = await part.open(mode: FileMode.append);
      // Batch disk writes; one writeFrom per 256 KB instead of per network
      // chunk cuts syscall overhead and measurably raises throughput.
      final buffer = BytesBuilder(copy: false);
      received = offset;
      task.received = received;
      _speedSampleAt = DateTime.now();
      _speedSampleBytes = received;
      var lastUi = DateTime.fromMillisecondsSinceEpoch(0);
      var lastDisk = DateTime.now();
      await for (final chunk in response.stream) {
        if (task.stage == DownloadStage.paused || _pausing.contains(task.id)) {
          break;
        }
        buffer.add(chunk);
        // 1 MiB batches: a fast link delivers several hundred KB per burst, so
        // larger writes cut syscalls (and CPU per byte) without adding latency.
        if (buffer.length >= 1024 * 1024) {
          await raf.writeFrom(buffer.takeBytes());
        }
        received += chunk.length;
        task.received = received;
        final now = DateTime.now();
        if (now.difference(lastDisk) > const Duration(milliseconds: 900)) {
          lastDisk = now;
          unawaited(_persist());
        }
        if (now.difference(lastUi).inMilliseconds > 250) {
          lastUi = now;
          final elapsed =
              now.difference(_speedSampleAt).inMilliseconds.clamp(1, 100000);
          final instant = (received - _speedSampleBytes) * 1000 / elapsed;
          // Smooth the reading: one burst on a very fast link otherwise makes
          // the speed number jump wildly between samples.
          _speedBytesPerSecond = _speedBytesPerSecond <= 0
              ? instant
              : _speedBytesPerSecond * 0.55 + instant * 0.45;
          _speedSampleBytes = received;
          _speedSampleAt = now;
          _safeNotify(force: true);
        }
      }
      if (buffer.length > 0) {
        await raf.writeFrom(buffer.takeBytes());
      }
      await raf.close();
      raf = null;
      if (task.stage == DownloadStage.paused || _pausing.contains(task.id)) {
        task.received = received;
        await _persist();
        _safeNotify();
        return;
      }
      if (!task.estimated && task.total > 0 && received < task.total) {
        throw const SocketException('Transfer ended early');
      }
      task.received = received;
      task.total = received;
      await _finalize(task);
    } on SocketException {
      task.received = received;
      _markWaiting(task, 'No internet — will resume automatically.');
    } on TimeoutException {
      task.received = received;
      _markWaiting(task, 'Connection timed out — will retry.');
    } on HttpException catch (e) {
      if (e.message.contains('page or HLS')) {
        task.stage = DownloadStage.failed;
        task.error = e.message;
      } else {
        task.received = received;
        _markWaiting(task, 'Server unreachable — will retry.');
      }
    } on http.ClientException {
      if (!_pausing.contains(task.id)) {
        task.received = received;
        _markWaiting(task, 'Connection lost — will resume.');
      }
    } on FileSystemException catch (e) {
      task.stage = DownloadStage.failed;
      task.error = 'Storage error: ${e.message}';
    } catch (_) {
      if (!_pausing.contains(task.id)) {
        task.received = received;
        _markWaiting(task, 'Download paused by an error — retrying.');
      }
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
      client?.close();
      _clients.remove(task.id);
      _running.remove(task.id);
      task.updatedAt = DateTime.now().millisecondsSinceEpoch;
      _pausing.remove(task.id);
      await _persist();
      _safeNotify();
      _syncKeepAlive();
      _pump();
    }
  }

  void _markWaiting(DownloadTask task, String message) {
    task.stage = DownloadStage.waitingNetwork;
    task.error = message;
    if (!_autoResume) task.stage = DownloadStage.paused;
  }

  int _totalFromContentRange(String? header) {
    if (header == null) return 0;
    final match = RegExp(r'/(\d+)\s*$').firstMatch(header);
    return int.tryParse(match?.group(1) ?? '') ?? 0;
  }

  Future<void> _finalize(DownloadTask task) async {
    final part = File('${_media!.path}/${task.id}.part');
    if (!await part.exists()) {
      task.stage = DownloadStage.failed;
      task.error = 'Download file disappeared before it finished.';
      return;
    }
    final size = await part.length();
    if (size < 1024) {
      task.stage = DownloadStage.failed;
      task.error = 'The episode file is empty.';
      return;
    }
    var target = task.fileName;
    var dest = File('${_media!.path}/$target');
    if (await dest.exists()) {
      target = '${task.id}-${task.fileName}';
      dest = File('${_media!.path}/$target');
    }
    await part.rename(dest.path);
    task
      ..localName = target
      ..received = size
      ..total = size
      ..estimated = false
      ..stage = DownloadStage.completed
      ..error = ''
      ..completedAt = DateTime.now().millisecondsSinceEpoch
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;
    // Heads-up alert the moment the episode is watchable offline.
    unawaited(AppNotifications.downloadComplete(
      animeTitle: task.animeTitle,
      episode: task.episode,
      taskId: task.id,
      imageUrl: task.image,
    ));
    // Exported copy (public Downloads) is best effort and never blocks saying
    // "completed": the in-app offline file is already playable.
    if (task.devicePath == null || task.devicePath!.isEmpty) {
      unawaited(_autoExport(task));
    }
  }

  Future<void> _autoExport(DownloadTask task) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool('save_to_device') ?? true)) return;
    } catch (_) {
      return;
    }
    await exportToDevice(task);
  }

  /// Copies a completed episode into public device storage and remembers where
  /// it went, so the Library can show the folder even after a restart.
  Future<String?> exportToDevice(DownloadTask task) async {
    if (task.stage != DownloadStage.completed) return null;
    final file = completedFile(task);
    if (file == null) return null;
    // One folder per anime in device storage: every saved episode of a series
    // lands together in `Download/CamAnime/<Anime title>/`, so any offline media
    // player can walk the folder and pick up the next episode on its own.
    final location = await DeviceStorage.save(
      sourcePath: file.path,
      folder: _safeName(task.animeTitle),
      subfolder: '',
      fileName: task.fileName,
    );
    if (location != null && location.isNotEmpty) {
      task.devicePath = location;
      task.updatedAt = DateTime.now().millisecondsSinceEpoch;
      await _persist();
      _safeNotify();
    }
    return location;
  }

  /// Saves every episode of one folder; returns how many copies were made.
  Future<int> exportFolder(DownloadFolder folder) async {
    var saved = 0;
    for (final task in folder.tasks) {
      if ((task.devicePath ?? '').isNotEmpty) continue;
      if (await exportToDevice(task) != null) saved++;
    }
    return saved;
  }

  Future<void> _persist() async {
    if (_root == null) return;
    try {
      final temp = File('${_root!.path}/queue.json.tmp');
      await temp.writeAsString(
          json.encode(_tasks.values.map((t) => t.toJson()).toList()),
          flush: true);
      final target = File('${_root!.path}/queue.json');
      if (await target.exists()) await target.delete();
      await temp.rename(target.path);
    } catch (_) {
      // The in-memory queue remains authoritative for this session.
    }
  }

  void _safeNotify({bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastNotify).inMilliseconds < 120) return;
    _lastNotify = now;
    notifyListeners();
  }

  void _syncKeepAlive() {
    unawaited(BackgroundKeepAlive.set(_running.isNotEmpty));
  }

  /// Extension of the file the server actually streams. Stitched HLS
  /// downloads are MPEG-TS; saving them as .mp4 makes the player pick the
  /// wrong extractor and fail.
  String _extensionFor(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    if (path.endsWith('/download/hls') || path.endsWith('.ts')) return 'ts';
    if (path.endsWith('.mkv')) return 'mkv';
    if (path.endsWith('.webm')) return 'webm';
    return 'mp4';
  }

  String _safeName(String raw) {
    final cleaned = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final clipped =
        cleaned.length > 90 ? cleaned.substring(0, 90).trim() : cleaned;
    return clipped.isEmpty ? 'CamAnime Episode' : clipped;
  }
}
