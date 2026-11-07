import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Backend is the CamAnime website itself — always on, no manual linking.
///   flutter build apk --release --dart-define=CAMANIME_API=https://your-host
const String apiHost = String.fromEnvironment(
  'CAMANIME_API',
  defaultValue: 'https://camanime.onrender.com',
);

/// One playable episode, carrying enough context for resume and back-to-back
/// playback without leaking UI state through globals.
///
/// [mirrors] holds the other servers the backend resolved for the same
/// episode; the player falls back to them in order when a source fails.
class EpisodeSource {
  final String url;
  final String label;
  final String animeId;
  final int? episode;
  final List<String> mirrors;
  final String animeTitle;
  final String image;

  const EpisodeSource({
    required this.url,
    required this.label,
    this.animeId = '',
    this.episode,
    this.mirrors = const [],
    this.animeTitle = '',
    this.image = '',
  });

  EpisodeSource copyWith({String? url, List<String>? mirrors}) => EpisodeSource(
        url: url ?? this.url,
        label: label,
        animeId: animeId,
        episode: episode,
        mirrors: mirrors ?? this.mirrors,
        animeTitle: animeTitle,
        image: image,
      );
}

/// One downloadable file the backend resolved for an episode.
///
/// Only direct video files are listed: HLS playlists and provider landing
/// pages cannot be saved by the downloader, so they are filtered out instead
/// of producing a broken offline entry.
class DownloadOption {
  final String label;
  final String audio;
  final String url;
  final int height;

  const DownloadOption({
    required this.label,
    required this.audio,
    required this.url,
    required this.height,
  });

  bool get isHd => height >= 1080;

  String get qualityLabel => height > 0 ? '${height}p' : 'Source file';
}

/// True when the URL points at an HLS playlist rather than a media file.
///
/// Only the path decides: a stitched download such as
/// `/api/download/hls?url=...master.m3u8` is a real file despite the query.
bool isPlaylistUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  final path = uri.path.toLowerCase();
  // The stitcher returns one media file, so its embedded playlist is fine.
  if (path.endsWith('/download/hls')) return false;
  if (path.endsWith('.m3u8') || path.endsWith('.m3u') || path.contains('mpegurl')) {
    return true;
  }
  // Older bundles wrap a playlist in the generic download proxy.
  final inner = uri.queryParameters['url'];
  if (inner != null) {
    final innerPath = Uri.tryParse(inner)?.path.toLowerCase() ?? '';
    if (innerPath.endsWith('.m3u8') || innerPath.endsWith('.m3u')) return true;
  }
  return false;
}

/// Extracts a pixel height (e.g. 720) from labels such as "720p MP4".
int downloadHeight(String raw) {
  final match = RegExp(r'(\d{3,4})\s*p', caseSensitive: false).firstMatch(raw);
  return match == null ? 0 : int.parse(match.group(1)!);
}

/// Direct, in-app downloadable files for an episode, preferred audio first
/// and smallest first. [absolute] turns backend paths into full URLs.
List<DownloadOption> downloadOptions(
  Map bundle, {
  required String preferredAudio,
  required String Function(String) absolute,
}) {
  final options = <DownloadOption>[];
  final seen = <String>{};

  void add(String label, Object? audio, String url, int height) {
    if (url.isEmpty) return;
    // A playlist itself is not worth saving; a stitched HLS file is.
    if (isPlaylistUrl(url)) return;
    final full = absolute(url);
    if (!seen.add(full)) return;
    final dub = (audio ?? '').toString().toLowerCase() == 'dub';
    options.add(DownloadOption(
      label: label,
      audio: dub ? 'dub' : 'sub',
      url: full,
      height: height,
    ));
  }

  for (final raw in (bundle['downloads'] as List?) ?? const []) {
    if (raw is! Map) continue;
    final url = (raw['url'] ?? '').toString();
    // `direct: false` entries are provider pages (Kiwi/Pahe), not files.
    if (raw['direct'] == false || isPlaylistUrl(url)) continue;
    final quality = (raw['quality'] ?? '').toString();
    final label = (raw['label'] ?? 'Episode file').toString();
    add(quality.isEmpty ? label : '$label · $quality', raw['audio'], url,
        downloadHeight(quality));
  }

  for (final raw in (bundle['servers'] as List?) ?? const []) {
    if (raw is! Map) continue;
    final mode = (raw['playback_mode'] ?? '').toString();
    // HLS servers expose a stitched single-file download, so they belong in the
    // same list as direct MP4 servers.
    if (mode != 'mp4' && mode != 'hls') continue;
    final url = (raw['download_url'] ?? '').toString();
    final quality = (raw['quality'] ?? 'MP4').toString();
    add('${raw['name'] ?? 'Direct MP4'} · $quality', raw['audio'], url,
        downloadHeight(quality));
  }

  options.sort((a, b) {
    final audioRank = (a.audio == preferredAudio ? 0 : 1)
        .compareTo(b.audio == preferredAudio ? 0 : 1);
    if (audioRank != 0) return audioRank;
    final aHeight = a.height == 0 ? 1 << 20 : a.height;
    final bHeight = b.height == 0 ? 1 << 20 : b.height;
    return aHeight.compareTo(bHeight);
  });
  return options;
}

/// Applies the saved "download_quality" preference.
///
/// Accepted values:
///  * `best` — highest resolution the servers offer;
///  * `smallest` — smallest available file;
///  * `360` / `480` / `720` / `1080` — the highest resolution at or below that
///    pixel height, so a 720p cap can never silently download a 1080p file;
///  * anything else (including `ask`) — smallest, as a safe default.
DownloadOption? pickDownloadOption(
    List<DownloadOption> options, String preference) {
  if (options.isEmpty) return null;
  final known = options.where((o) => o.height > 0).toList();
  final pool = known.isEmpty ? [...options] : known;
  if (preference == 'best') {
    pool.sort((a, b) => b.height.compareTo(a.height));
    return pool.first;
  }
  final target = int.tryParse(preference);
  if (target != null && target > 0) {
    final atOrBelow = pool.where((o) => o.height <= target).toList();
    if (atOrBelow.isNotEmpty) {
      atOrBelow.sort((a, b) => b.height.compareTo(a.height));
      return atOrBelow.first;
    }
    // Nothing that small is offered — take the smallest real file.
    pool.sort((a, b) => a.height.compareTo(b.height));
    return pool.first;
  }
  pool.sort((a, b) => a.height.compareTo(b.height));
  return pool.first;
}

/// Human label for a saved download quality preference.
String downloadQualityLabel(String preference) {
  if (preference == 'ask') return 'Ask each time';
  if (preference == 'best') return 'Best available';
  if (preference == 'smallest') return 'Smallest file';
  final height = int.tryParse(preference) ?? 720;
  return '${height}p or lower';
}

/// Where the user left off, per anime + episode, in plain JSON prefs.
class WatchProgress {
  static const _key = 'watch_progress_v1';

  static Future<Map<String, dynamic>> _load() async {
    final p = await SharedPreferences.getInstance();
    try {
      return (json.decode(p.getString(_key) ?? '{}') as Map)
          .cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }

  static Future<void> _save(Map<String, dynamic> map) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, json.encode(map));
  }

  /// Latest saved position for an episode. Returns null when nothing was
  /// meaningfully started or the episode was nearly finished.
  static Future<int?> position(String animeId, int episode) async {
    final data = await _load();
    final entry = (data[animeId] as Map?)?[episode.toString()];
    if (entry is! Map) return null;
    final pos = (int.tryParse('${entry['posMs'] ?? ''}') ?? 0);
    final dur = (int.tryParse('${entry['durMs'] ?? ''}') ?? 0);
    if (pos < 15000 || (dur > 0 && pos >= dur * 0.95)) return null;
    if (dur > 0 && pos > dur) return null;
    return pos;
  }

  /// The most recently touched episode for this anime, for a resume chip.
  static Future<Map<String, dynamic>?> latest(String animeId) async {
    final data = await _load();
    final forAnime = ((data[animeId] as Map?) ?? {}).cast<String, dynamic>();
    if (forAnime.isEmpty) return null;
    Map<String, dynamic>? best;
    var bestT = -1;
    forAnime.forEach((ep, entry) {
      if (entry is Map) {
        final t = int.tryParse('${entry['updated'] ?? ''}') ?? 0;
        if (t > bestT) {
          bestT = t;
          best = {
            ...entry.cast<String, dynamic>(),
            'ep': int.tryParse(ep) ?? 0
          };
        }
      }
    });
    final b = best;
    if (b == null) return null;
    final pos = int.tryParse((b['posMs'] ?? '').toString()) ?? 0;
    final dur = int.tryParse((b['durMs'] ?? '').toString()) ?? 0;
    if (pos < 15000 || (dur > 0 && pos >= dur * 0.95) || (b['ep'] ?? 0) == 0) {
      return null;
    }
    return b;
  }

  static Future<void> save({
    required String animeId,
    required String animeTitle,
    required String image,
    required int episode,
    required int posMs,
    required int durMs,
  }) async {
    final data = await _load();
    final anime = ((data[animeId] as Map?) ?? {}).cast<String, dynamic>();
    anime[episode.toString()] = {
      'title': animeTitle.substring(0, animeTitle.length.clamp(0, 80)),
      'image': image,
      'posMs': posMs,
      'durMs': durMs,
      'updated': DateTime.now().millisecondsSinceEpoch,
    };
    data[animeId] = anime;
    // Keep the map bounded so prefs never balloon on a long-lived device.
    while (data.length > 60) {
      String? oldest;
      var oldestT = 1 << 40;
      for (final entry in data.entries) {
        final anime = (entry.value as Map?) ?? {};
        var t = 1 << 40;
        for (final row in anime.values) {
          if (row is Map) {
            t = (int.tryParse('${row['updated'] ?? ''}') ?? t);
            if (t < oldestT) {
              oldestT = t;
              oldest = entry.key.toString();
            }
          }
        }
      }
      if (oldest == null) break;
      data.remove(oldest);
    }
    await _save(data);
  }

  static Future<void> clear(String animeId, int episode) async {
    final data = await _load();
    final anime = ((data[animeId] as Map?) ?? {}).cast<String, dynamic>();
    anime.remove(episode.toString());
    data[animeId] = anime;
    await _save(data);
  }

  /// Wipes every resume position (Settings → Clear watch history).
  static Future<void> clearAll() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_key);
  }

  /// Every in-progress episode, newest first — used by Library.
  static Future<List<Map<String, dynamic>>> all() async {
    final data = await _load();
    final rows = <Map<String, dynamic>>[];
    data.forEach((animeId, value) {
      if (value is! Map) return;
      value.forEach((ep, entry) {
        if (entry is! Map) return;
        final pos = int.tryParse('${entry['posMs'] ?? ''}') ?? 0;
        final dur = int.tryParse('${entry['durMs'] ?? ''}') ?? 0;
        if (pos < 15000 || (dur > 0 && pos >= dur * 0.95)) return;
        rows.add({
          ...entry.cast<String, dynamic>(),
          'anime_id': animeId,
          'ep': int.tryParse('$ep') ?? 0,
        });
      });
    });
    rows.sort((a, b) => (int.tryParse('${b['updated'] ?? ''}') ?? 0)
        .compareTo(int.tryParse('${a['updated'] ?? ''}') ?? 0));
    return rows;
  }
}
