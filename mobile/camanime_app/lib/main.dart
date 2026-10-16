import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

// ── Release line ───────────────────────────────────────
const String appVersion = '1.2.0';
const String appCredit = 'Made by kayefande-droid & co.';

// Backend is the CamAnime website itself — always on, no manual linking.
//   flutter build apk --release --dart-define=CAMANIME_API=https://your-host
const String apiHost = String.fromEnvironment(
  'CAMANIME_API',
  defaultValue: 'https://camanime.onrender.com',
);

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

void main() => runApp(const CamAnimeApp());

class CamAnimeApp extends StatefulWidget {
  const CamAnimeApp({super.key});
  @override
  State<CamAnimeApp> createState() => _CamAnimeAppState();
}

class _CamAnimeAppState extends State<CamAnimeApp> {
  int tab = 0;
  bool showTutorial = false;
  String themeName = 'midnight';

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
    _firstRun();
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
    } else {
      _checkUpdate();
    }
  }

  Future<void> _checkUpdate({bool manual = false}) async {
    try {
      final r = await http
          .get(Uri.parse('$apiHost/api/version'))
          .timeout(const Duration(seconds: 12));
      final d = json.decode(r.body) as Map<String, dynamic>;
      final latest = (d['app_version'] ?? '').toString();
      if (latest.isNotEmpty && latest != appVersion && mounted) {
        _updateDialog(latest);
      } else if (manual && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('You are on the latest version ($appVersion)')));
      }
    } catch (_) {
      if (manual && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not reach the website — check internet.')));
      }
    }
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
              setState(() => tab = 3);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Open Library → App update to download.')));
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
    final t = appThemes[themeName] ?? appThemes['midnight']!;
    final seed = Color(t['seed'] as int);
    final scaffold = Color(t['bg'] as int);
    return MaterialApp(
      title: 'CamAnime',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: scaffold,
        colorScheme: ColorScheme.fromSeed(
            seedColor: seed, brightness: Brightness.dark, primary: seed),
        cardTheme: CardThemeData(
            color: card,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18))),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: card2,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none),
          hintStyle: const TextStyle(color: muted),
        ),
      ),
      home: Stack(
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
                await Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => SettingsScreen(
                            themeName: themeName,
                            onTheme: _applyTheme,
                            onCheckUpdate: () => _checkUpdate(manual: true))));
              },
            ),
          ),
          if (showTutorial)
            TutorialOverlay(onDone: () async {
              final p = await SharedPreferences.getInstance();
              await p.setBool('tutorial_done', true);
              setState(() => showTutorial = false);
              _checkUpdate();
            }),
        ],
      ),
    );
  }
}

// ── Floating bottom navigation + gear ──────────────────
class _FloatingNav extends StatelessWidget {
  final int tab;
  final List<(String, IconData, IconData)> tabs;
  final ValueChanged<int> onTab;
  final VoidCallback onSettings;
  const _FloatingNav(
      {required this.tab,
      required this.tabs,
      required this.onTab,
      required this.onSettings});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xF20B0E16),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: const Color(0x33FFB347)),
            boxShadow: const [
              BoxShadow(
                  color: Colors.black54, blurRadius: 18, offset: Offset(0, 6))
            ],
          ),
          child: Row(children: [
            for (var i = 0; i < tabs.length; i++)
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () => onTab(i),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    decoration: BoxDecoration(
                      color: tab == i
                          ? amber.withValues(alpha: 0.16)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(tab == i ? tabs[i].$3 : tabs[i].$2,
                          size: 23, color: tab == i ? amber : muted),
                      const SizedBox(height: 2),
                      Text(tabs[i].$1,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: tab == i ? amber : muted)),
                    ]),
                  ),
                ),
              ),
            Container(
              margin: const EdgeInsets.only(left: 2),
              decoration: BoxDecoration(
                  color: card2, borderRadius: BorderRadius.circular(18)),
              child: IconButton(
                tooltip: 'App settings',
                icon:
                    const Icon(Icons.settings_outlined, size: 23, color: muted),
                onPressed: onSettings,
              ),
            ),
          ]),
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
    return {if (t != null) 'Authorization': 'Bearer $t'};
  }

  static Future<String> guestName() async {
    final p = await SharedPreferences.getInstance();
    return (p.getString('username') ?? '').trim();
  }

  static Future<int> avatarIdx() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt('avatar_idx') ?? 0;
  }

  static bool _isTransientStatus(int status) => status >= 500;
  static const bool _testMode = bool.fromEnvironment('FLUTTER_TEST');

  static Future<http.Response> _get(Uri uri,
      {Duration timeout = const Duration(seconds: 20)}) async {
    Object? lastError;
    final attempts = _testMode ? 1 : 2;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        final response = await http.get(uri).timeout(timeout);
        if (_isTransientStatus(response.statusCode) && attempt + 1 < attempts) {
          await Future<void>.delayed(const Duration(milliseconds: 350));
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
          await Future<void>.delayed(const Duration(milliseconds: 350));
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

  /// Synced admin/secret status — admin only, same backend the website uses.
  static Future<Map<String, dynamic>> adminSync() async {
    final r = await http
        .get(Uri.parse('${base()}/api/admin/sync'), headers: await headers())
        .timeout(const Duration(seconds: 12));
    final d = json.decode(r.body) as Map<String, dynamic>;
    if (d['status'] != 'success') {
      throw Exception(d['error'] ?? 'Admin sync failed');
    }
    return d;
  }

  /// Change own admin password (admin only). Clears server tokens on success.
  static Future<void> changeAdminPassword(
      String currentPassword, String newPassword) async {
    final r = await http.post(Uri.parse('${base()}/api/admin/password'),
        headers: {...await headers(), 'Content-Type': 'application/json'},
        body: json.encode({
          'current_password': currentPassword,
          'new_password': newPassword,
        }));
    final d = json.decode(r.body) as Map<String, dynamic>;
    if (d['status'] != 'success') {
      throw Exception(d['error'] ?? 'Password change failed');
    }
    await signOut();
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
      ann = [];
  Map? featured;
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

  Future<void> _load() async {
    _lastRefresh = DateTime.now();
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
        featured = hero;
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
    if (featured != null) out.add(_featuredCard(featured!));
    out.add(_rail('Trending Anime', trending));
    out.add(_rail('Popular this season', popular));
    out.add(_rail('Top Rated', topRated));
    out.add(_rail('Recently Added', fresh));
    out.add(_rail('Popular Movies', movies));
    out.add(_rail('Popular Series', series));
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
                      _miniRail('Trending now', trending),
                      _miniRail('Popular this season', popular),
                      _miniRail('Top rated', topRated),
                      _miniRail('Movies', movies),
                    ],
                  ])),
    );
  }

  Widget _miniRail(String title, List items) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
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

// ── Detail: banner, seasons, episodes, downloads, forum ─
class DetailScreen extends StatefulWidget {
  final String animeId;
  final String title;
  const DetailScreen({super.key, required this.animeId, required this.title});
  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen>
    with SingleTickerProviderStateMixin {
  Map info = {};
  bool loading = true;
  String audio = 'sub';
  String season = 'Season 1';
  final Set<int> selected = {};
  bool dlBusy = false;
  double? dlProgress;
  String dlStatus = '';
  List comments = [];
  bool commentsBusy = false;
  String commentError = '';
  final _commentCtrl = TextEditingController();
  int? myScore;
  late TabController _tabs;

  int get totalEps {
    final n = int.tryParse((info['episode_count'] ?? '').toString()) ?? 0;
    if (n > 0) return n > 200 ? 200 : n;
    return 12;
  }

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _init();
  }

  Future<void> _init() async {
    final p = await SharedPreferences.getInstance();
    audio = (p.getString('app_audio') ?? 'sub') == 'dub' ? 'dub' : 'sub';
    await _load();
    await _loadComments();
  }

  Future<void> _load() async {
    try {
      final d = await Api.animeInfo(widget.animeId);
      if (!mounted) return;
      setState(() {
        info = d;
        loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
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

  Future<Map<String, dynamic>?> _sourcesFor(int ep) async {
    try {
      return await Api.episodeSources(widget.animeId, ep, audio);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? _selectServer(Map bundle) {
    final servers = (bundle['servers'] as List?) ?? [];
    final candidates = servers
        .whereType<Map>()
        .map((s) => s.cast<String, dynamic>())
        .where(
            (s) => s['playback_mode'] == 'mp4' || s['playback_mode'] == 'hls')
        .toList();
    if (candidates.isEmpty) return null;
    for (final server in candidates) {
      if (server['audio'] == audio) return server;
    }
    return candidates.first;
  }

  String? _playableUrl(Map bundle) {
    final server = _selectServer(bundle);
    final path = (server?['stream_url'] ?? '').toString();
    return path.isEmpty ? null : Api.abs(path);
  }

  Map<String, dynamic>? _downloadSource(Map bundle) {
    final servers = (bundle['servers'] as List?) ?? [];
    for (final raw in servers) {
      if (raw is! Map) continue;
      final server = raw.cast<String, dynamic>();
      if (server['audio'] == audio &&
          server['playback_mode'] == 'mp4' &&
          (server['download_url'] ?? '').toString().isNotEmpty) {
        return server;
      }
    }
    for (final raw in servers) {
      if (raw is! Map) continue;
      final server = raw.cast<String, dynamic>();
      if (server['playback_mode'] == 'mp4' &&
          (server['download_url'] ?? '').toString().isNotEmpty) {
        return server;
      }
    }
    return null;
  }

  Future<void> _play(int ep) async {
    final bundle = await _sourcesFor(ep);
    if (!mounted) return;
    if (bundle == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not reach streaming servers — try again.')));
      return;
    }
    final url = _playableUrl(bundle);
    if (url == null || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Only embed servers available — watch on the site.')));
      return;
    }
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => PlayerScreen(
                url: url,
                label:
                    '${(info['title'] ?? widget.title).toString()} — Ep $ep (${audio.toUpperCase()})')));
  }

  Future<void> _downloadEp(int ep) async {
    setState(() {
      dlBusy = true;
      dlProgress = 0;
      dlStatus = 'Resolving Episode $ep…';
    });
    try {
      final bundle = await _sourcesFor(ep);
      if (bundle == null) throw const HttpException('No servers reachable');
      final title = '${(info['title'] ?? widget.title).toString()} - Ep $ep';
      final server = _downloadSource(bundle);
      if (server == null) {
        throw const HttpException(
            'No direct MP4 download is available for this episode. HLS/embeds are stream-only.');
      }
      final url = Api.abs(server['download_url'].toString());
      final result = await Api.downloadEpisodeFile(url, '$title.mp4',
          onProgress: (rec, total) {
        if (mounted && total > 0) {
          setState(() {
            dlProgress = rec / total;
            dlStatus = 'Saving Episode $ep… ${(100 * rec / total).round()}%';
          });
        }
      });
      await MediaLibrary.record(
        file: result.file,
        title: title,
        animeId: int.tryParse(widget.animeId) ?? 0,
        episode: ep,
        audio: (server['audio'] ?? audio).toString(),
        sizeBytes: result.downloadedBytes,
      );
      if (mounted) {
        setState(() => dlStatus =
            'Downloaded and verified: ${result.file.uri.pathSegments.last}');
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Download verified ✓ — available in My Library offline.')));
      }
    } catch (e) {
      if (mounted) setState(() => dlStatus = 'Episode $ep failed: $e');
    }
    if (mounted) {
      setState(() {
        dlBusy = false;
        dlProgress = null;
      });
    }
  }

  Future<void> _downloadSelected() async {
    if (selected.isEmpty) return;
    final eps = selected.toList()..sort();
    setState(() {
      dlBusy = true;
      dlStatus = 'Starting ${eps.length} downloads…';
    });
    var done = 0;
    for (final ep in eps) {
      if (!mounted) break;
      setState(() {
        dlStatus = 'Episode $ep (${done + 1}/${eps.length})…';
        dlProgress = done / eps.length;
      });
      try {
        final bundle = await _sourcesFor(ep);
        final title = '${(info['title'] ?? widget.title).toString()} - Ep $ep';
        final server = bundle == null ? null : _downloadSource(bundle);
        if (server != null) {
          final result = await Api.downloadEpisodeFile(
              Api.abs(server['download_url'].toString()), '$title.mp4');
          await MediaLibrary.record(
            file: result.file,
            title: title,
            animeId: int.tryParse(widget.animeId) ?? 0,
            episode: ep,
            audio: (server['audio'] ?? audio).toString(),
            sizeBytes: result.downloadedBytes,
          );
          done++;
        }
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        dlBusy = false;
        dlProgress = null;
        dlStatus = 'Finished: $done/${eps.length} saved to My Library.';
        selected.clear();
      });
    }
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final poster = (info['image'] ?? '').toString();
    final backdrop = (info['banner'] ?? poster).toString();
    final genres = (info['genres'] as List?) ?? [];
    return Scaffold(
      appBar: AppBar(
          title:
              Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: loading
          ? const Center(child: CircularProgressIndicator(color: amber))
          : ListView(padding: const EdgeInsets.only(bottom: 24), children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(fit: StackFit.expand, children: [
                  CachedPosterImage(url: backdrop),
                  const DecoratedBox(
                      decoration: BoxDecoration(
                          gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Color(0x22000000), Color(0xFF07080D)]))),
                  Positioned(
                      left: 18,
                      right: 18,
                      bottom: 14,
                      child: Text((info['title'] ?? widget.title).toString(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 24, fontWeight: FontWeight.w900))),
                ]),
              ),
              Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ClipRRect(
                                  borderRadius: BorderRadius.circular(14),
                                  child: SizedBox(
                                      width: 100,
                                      child: AspectRatio(
                                          aspectRatio: 2 / 2.85,
                                          child:
                                              CachedPosterImage(url: poster)))),
                              const SizedBox(width: 14),
                              Expanded(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                    Text(
                                        (info['title_native'] ?? '').toString(),
                                        style: const TextStyle(
                                            color: muted, fontSize: 12)),
                                    const SizedBox(height: 8),
                                    Text(
                                        '${info['year'] ?? 'Year unknown'} · ${info['format'] ?? 'Anime'} · ${info['status'] ?? ''}',
                                        style: const TextStyle(
                                            color: muted, fontSize: 12)),
                                    const SizedBox(height: 8),
                                    Text('★ Rating ${info['rating'] ?? 'N/A'}',
                                        style: const TextStyle(
                                            color: amber,
                                            fontWeight: FontWeight.w700)),
                                    const SizedBox(height: 8),
                                    Text('$totalEps episodes · $season',
                                        style: const TextStyle(
                                            color: muted, fontSize: 12)),
                                  ])),
                            ]),
                        if (genres.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          Wrap(spacing: 7, runSpacing: 7, children: [
                            for (final genre in genres)
                              Chip(
                                  label: Text(genre.toString()),
                                  visualDensity: VisualDensity.compact,
                                  backgroundColor: card2,
                                  side: BorderSide.none)
                          ]),
                        ],
                        if ((info['description'] ?? '')
                            .toString()
                            .isNotEmpty) ...[
                          const SizedBox(height: 14),
                          Text(info['description'].toString(),
                              style:
                                  const TextStyle(color: muted, fontSize: 13)),
                        ],
                        const SizedBox(height: 16),
                        Row(children: [
                          Expanded(
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(
                                  backgroundColor: amber,
                                  foregroundColor: Colors.black,
                                  minimumSize: const Size(0, 50)),
                              onPressed: dlBusy ? null : () => _play(1),
                              icon: const Icon(Icons.play_arrow),
                              label: const Text('Watch Ep 1'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                  minimumSize: const Size(0, 50)),
                              onPressed: dlBusy ? null : () => _downloadEp(1),
                              icon: const Icon(Icons.download),
                              label: const Text('Get Ep 1'),
                            ),
                          ),
                        ]),
                        const SizedBox(height: 14),
                        const Text('Rate this anime',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 6),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(children: [
                            for (var s = 1; s <= 10; s++)
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: ChoiceChip(
                                  label: Text('$s'),
                                  selected: myScore == s,
                                  onSelected: (_) => _rate(s),
                                ),
                              ),
                          ]),
                        ),
                        const SizedBox(height: 16),
                        Row(children: [
                          const Text('Audio:',
                              style: TextStyle(fontWeight: FontWeight.w800)),
                          const SizedBox(width: 10),
                          SegmentedButton<String>(
                            segments: const [
                              ButtonSegment(
                                  value: 'sub',
                                  label: Text('SUB'),
                                  icon: Icon(Icons.closed_caption)),
                              ButtonSegment(
                                  value: 'dub',
                                  label: Text('DUB'),
                                  icon: Icon(Icons.headphones)),
                            ],
                            selected: {audio},
                            onSelectionChanged: (s) async {
                              setState(() => audio = s.first);
                              final p = await SharedPreferences.getInstance();
                              await p.setString('app_audio', s.first);
                            },
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              initialValue: season,
                              decoration: const InputDecoration(
                                  labelText: 'Season',
                                  contentPadding: EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 8)),
                              items: const [
                                DropdownMenuItem(
                                    value: 'Season 1', child: Text('Season 1')),
                              ],
                              onChanged: (v) =>
                                  setState(() => season = v ?? 'Season 1'),
                            ),
                          ),
                        ]),
                        const SizedBox(height: 12),
                        Row(children: [
                          Text('Episodes (1–$totalEps)',
                              style: const TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.w800)),
                          const Spacer(),
                          TextButton(
                              onPressed: () => setState(() {
                                    if (selected.length == totalEps) {
                                      selected.clear();
                                    } else {
                                      selected.addAll(List.generate(
                                          totalEps, (i) => i + 1));
                                    }
                                  }),
                              child: Text(selected.length == totalEps
                                  ? 'Clear all'
                                  : 'Select all')),
                        ]),
                        const Text(
                            'Tap to play · tick to multi-select · ⬇ saves the direct MP4.',
                            style: TextStyle(color: muted, fontSize: 12)),
                        const SizedBox(height: 8),
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 4,
                                  childAspectRatio: 1.15,
                                  crossAxisSpacing: 8,
                                  mainAxisSpacing: 8),
                          itemCount: totalEps,
                          itemBuilder: (_, i) {
                            final ep = i + 1;
                            final on = selected.contains(ep);
                            return InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () => _play(ep),
                              onLongPress: () => setState(() {
                                on ? selected.remove(ep) : selected.add(ep);
                              }),
                              child: Container(
                                decoration: BoxDecoration(
                                  color:
                                      on ? amber.withValues(alpha: 0.2) : card2,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                      color: on ? amber : Colors.transparent,
                                      width: 2),
                                ),
                                child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Checkbox(
                                                value: on,
                                                visualDensity:
                                                    VisualDensity.compact,
                                                materialTapTargetSize:
                                                    MaterialTapTargetSize
                                                        .shrinkWrap,
                                                onChanged: (_) => setState(() {
                                                      on
                                                          ? selected.remove(ep)
                                                          : selected.add(ep);
                                                    })),
                                            Text('$ep',
                                                style: const TextStyle(
                                                    fontWeight:
                                                        FontWeight.w800)),
                                          ]),
                                      InkWell(
                                        onTap: () => _downloadEp(ep),
                                        child: const Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Icon(Icons.download_rounded,
                                                  size: 15, color: mint),
                                              SizedBox(width: 3),
                                              Text('MP4',
                                                  style: TextStyle(
                                                      fontSize: 11,
                                                      color: mint,
                                                      fontWeight:
                                                          FontWeight.w700)),
                                            ]),
                                      ),
                                    ]),
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                                backgroundColor: mint,
                                foregroundColor: Colors.black,
                                minimumSize: const Size(0, 50)),
                            onPressed: (dlBusy || selected.isEmpty)
                                ? null
                                : _downloadSelected,
                            icon: const Icon(Icons.download),
                            label: Text(selected.isEmpty
                                ? 'Download selected (tick episodes)'
                                : 'Download ${selected.length} selected'),
                          ),
                        ),
                        if (dlProgress != null) ...[
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                              value: dlProgress, color: mint),
                        ],
                        if (dlStatus.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(dlStatus,
                              style:
                                  const TextStyle(color: muted, fontSize: 12)),
                        ],
                        const SizedBox(height: 18),
                        TabBar(
                          controller: _tabs,
                          tabs: const [
                            Tab(text: 'For you'),
                            Tab(text: 'Comments'),
                          ],
                        ),
                        SizedBox(
                          height: 430,
                          child: TabBarView(
                            controller: _tabs,
                            children: [
                              _RelatedPane(
                                  animeId: widget.animeId,
                                  genres:
                                      genres.map((e) => e.toString()).toList()),
                              _CommentsPane(
                                comments: comments,
                                busy: commentsBusy,
                                error: commentError,
                                controller: _commentCtrl,
                                onPost: _postComment,
                                onRefresh: _loadComments,
                              ),
                            ],
                          ),
                        ),
                      ])),
            ]),
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
      ];
      pool.shuffle();
      if (mounted) {
        setState(() {
          items = pool
              .where((e) => (e as Map)['id'].toString() != widget.animeId)
              .take(9)
              .toList();
          busy = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const Center(child: CircularProgressIndicator(color: amber));
    }
    if (items.isEmpty) {
      return const Center(
          child:
              Text('No recommendations yet.', style: TextStyle(color: muted)));
    }
    return GridView.builder(
      padding: const EdgeInsets.only(top: 12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          childAspectRatio: 0.56,
          crossAxisSpacing: 10,
          mainAxisSpacing: 12),
      itemCount: items.length,
      itemBuilder: (_, i) =>
          PosterCard(item: items[i] as Map, width: double.infinity),
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
    return Column(children: [
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: controller,
              decoration: const InputDecoration(
                  hintText: 'Comment as guest…',
                  prefixIcon: Icon(Icons.chat_bubble_outline)),
              onSubmitted: (_) => onPost(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: amber,
                foregroundColor: Colors.black,
                minimumSize: const Size(0, 48)),
            onPressed: onPost,
            child: const Text('Post'),
          ),
        ]),
      ),
      if (error.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(error, style: const TextStyle(color: pink, fontSize: 12)),
        ),
      Expanded(
        child: busy
            ? const Center(child: CircularProgressIndicator(color: amber))
            : comments.isEmpty
                ? Center(
                    child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                        const Icon(Icons.forum_outlined,
                            size: 44, color: muted),
                        const SizedBox(height: 8),
                        const Text('No comments yet — start the forum.',
                            style: TextStyle(color: muted)),
                        TextButton(
                            onPressed: onRefresh,
                            child: const Text('Refresh comments')),
                      ]))
                : RefreshIndicator(
                    color: amber,
                    backgroundColor: card,
                    onRefresh: () async => onRefresh(),
                    child: ListView.builder(
                      padding: const EdgeInsets.only(top: 8),
                      itemCount: comments.length,
                      itemBuilder: (_, i) {
                        final c = comments[i] as Map;
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: CircleAvatar(
                                backgroundColor: card2,
                                child: Text(
                                    ((c['user'] ?? 'G')
                                            .toString()
                                            .characters
                                            .firstOrNull ??
                                        'G'),
                                    style: const TextStyle(
                                        color: amber,
                                        fontWeight: FontWeight.w800))),
                            title: Text((c['user'] ?? 'Guest').toString(),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800, fontSize: 13)),
                            subtitle: Text(
                                (c['text'] ?? c['sticker'] ?? '').toString()),
                            trailing:
                                Row(mainAxisSize: MainAxisSize.min, children: [
                              const Icon(Icons.favorite, size: 14, color: pink),
                              const SizedBox(width: 3),
                              Text('${c['likes'] ?? 0}',
                                  style: const TextStyle(
                                      color: muted, fontSize: 12)),
                            ]),
                          ),
                        );
                      },
                    ),
                  ),
      ),
    ]);
  }
}

// ── Player (website's own MP4/HLS streams, in-app) ──────
class PlayerScreen extends StatefulWidget {
  final String url;
  final String label;
  final bool localFile;
  const PlayerScreen(
      {super.key,
      required this.url,
      required this.label,
      this.localFile = false});
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  VideoPlayerController? _video;
  ChewieController? _chewie;
  String? error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final v = widget.localFile
          ? VideoPlayerController.file(File(widget.url))
          : VideoPlayerController.networkUrl(Uri.parse(widget.url));
      await v.initialize();
      final c = ChewieController(
        videoPlayerController: v,
        autoPlay: true,
        looping: false,
        allowFullScreen: true,
        allowPlaybackSpeedChanging: true,
        errorBuilder: (_, msg) => Center(
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Playback error: $msg',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: muted)))),
      );
      if (!mounted) {
        await v.dispose();
        c.dispose();
        return;
      }
      setState(() {
        _video = v;
        _chewie = c;
      });
    } catch (e) {
      if (mounted) setState(() => error = 'Stream failed: $e');
    }
  }

  @override
  void dispose() {
    _chewie?.dispose();
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: Text(widget.label,
                maxLines: 1, overflow: TextOverflow.ellipsis)),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Container(
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18), color: Colors.black),
            clipBehavior: Clip.antiAlias,
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: error != null
                  ? Center(
                      child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: muted))))
                  : _chewie == null
                      ? const Center(
                          child: CircularProgressIndicator(color: amber))
                      : Chewie(controller: _chewie!),
            ),
          ),
          const SizedBox(height: 10),
          Text(
              widget.localFile
                  ? 'Playing downloaded file offline-ready from My Library.'
                  : 'Streaming directly from CamAnime website servers — no download required.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: muted, fontSize: 12)),
          const SizedBox(height: 4),
          const Text(appCredit,
              textAlign: TextAlign.center,
              style: TextStyle(color: muted, fontSize: 12)),
        ]),
      );
}

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
      setState(() {
        results = found;
        error = found.isEmpty ? 'No matching anime found.' : null;
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
class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key});
  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  List<FileSystemEntity> files = [];
  Map ver = {};
  bool busy = false;
  double? progress;

  @override
  void initState() {
    super.initState();
    _load();
    _checkVersion();
  }

  Future<void> _load() async {
    final dir = await getApplicationSupportDirectory();
    final lib = Directory('${dir.path}/camanime_library');
    if (!await lib.exists()) {
      await lib.create(recursive: true);
    }
    if (!mounted) {
      return;
    }
    final all = lib.listSync().whereType<File>().toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    setState(() => files = all);
  }

  Future<void> _checkVersion() async {
    try {
      final v = await Api.version();
      if (mounted) setState(() => ver = v);
    } catch (_) {}
  }

  Future<void> _saveToDevice(File f) async {
    try {
      final pub = await getDownloadsDirectory() ??
          await getApplicationDocumentsDirectory();
      await f.copy('${pub.path}/${f.uri.pathSegments.last}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Saved to device Downloads')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    }
  }

  Future<void> _delete(File f) async {
    try {
      await f.delete();
    } catch (_) {}
    await _load();
  }

  Future<void> _downloadUpdate() async {
    setState(() {
      busy = true;
      progress = 0;
    });
    try {
      final req = http.Request('GET', Uri.parse('${Api.base()}/get/android'));
      final resp = await http.Client().send(req);
      final total = resp.contentLength ?? 0;
      final dir = await getDownloadsDirectory() ??
          await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/CamAnime-update.apk');
      final sink = f.openWrite();
      var got = 0;
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (mounted && total > 0) {
          setState(() => progress = got / total);
        }
      }
      await sink.close();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Update saved to Downloads — open CamAnime-update.apk to install.')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Download failed — check internet.')));
      }
    }
    if (mounted) {
      setState(() {
        busy = false;
        progress = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final latest = (ver['app_version'] ?? '').toString();
    final hasUpdate = latest.isNotEmpty && latest != appVersion;
    return SafeArea(
      child: RefreshIndicator(
        color: amber,
        backgroundColor: card,
        onRefresh: _load,
        child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
            children: [
              const Text('My Library',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
              const Text(
                  'Episodes you download in the app land here — offline, always yours.',
                  style: TextStyle(color: muted, fontSize: 12)),
              const SizedBox(height: 10),
              if (hasUpdate)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.system_update, color: amber),
                    title: Text('App update $latest available',
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                    subtitle: progress != null
                        ? LinearProgressIndicator(value: progress, color: amber)
                        : const Text('From your CamAnime website'),
                    trailing: FilledButton(
                        style: FilledButton.styleFrom(
                            backgroundColor: amber,
                            foregroundColor: Colors.black),
                        onPressed: busy ? null : _downloadUpdate,
                        child: Text(busy ? '…' : 'Get')),
                  ),
                ),
              const SizedBox(height: 6),
              if (files.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 30),
                  child: Column(children: [
                    Icon(Icons.video_library_outlined, size: 64, color: muted),
                    SizedBox(height: 10),
                    Text('No downloads yet',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w800)),
                    Text('Open any anime → tick episodes → Download.',
                        style: TextStyle(color: muted)),
                  ]),
                )
              else
                for (final e in files)
                  Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: ListTile(
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => PlayerScreen(
                                  url: e.path,
                                  label: e.uri.pathSegments.last,
                                  localFile: true))),
                      leading: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                              color: purple.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(12)),
                          child: const Icon(Icons.movie, color: purple)),
                      title: Text((e as File).uri.pathSegments.last,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text(
                          '${(e.statSync().size / 1048576).toStringAsFixed(1)} MB',
                          style: const TextStyle(color: muted, fontSize: 12)),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                            tooltip: 'Delete',
                            icon:
                                const Icon(Icons.delete_outline, color: muted),
                            onPressed: () => _delete(e)),
                        FilledButton(
                            style: FilledButton.styleFrom(
                                backgroundColor: amber,
                                foregroundColor: Colors.black),
                            onPressed: () => _saveToDevice(e),
                            child: const Text('Save')),
                      ]),
                    ),
                  ),
            ]),
      ),
    );
  }
}

// ── Profile (avatar, name, connection, auth) ───────────
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

  Future<void> _who() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) {
      return;
    }
    setState(() => who = p.getString('user_email'));
  }

  Future<void> _go(bool register) async {
    setState(() => busy = true);
    try {
      final u = await Api.signIn(email.text.trim(), password.text,
          register: register, name: email.text.split('@').first);
      if (!mounted) {
        return;
      }
      setState(() => who = u['email'] as String?);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Signed in as ${u['email']} — synced with website')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (who != null) {
      return Card(
          child: ListTile(
        leading: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
                color: mint.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.verified_user, color: mint)),
        title: Text(who!, style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: const Text('Synced with the website database',
            style: TextStyle(color: muted, fontSize: 12)),
        trailing: TextButton(
            onPressed: () async {
              await Api.signOut();
              _who();
            },
            child: const Text('Sign out')),
      ));
    }
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
                      labelText: 'Password',
                      prefixIcon: Icon(Icons.lock_outline))),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                    child: FilledButton(
                        style: FilledButton.styleFrom(
                            backgroundColor: amber,
                            foregroundColor: Colors.black),
                        onPressed: busy ? null : () => _go(false),
                        child: Text(busy ? 'Please wait…' : 'Sign in'))),
                const SizedBox(width: 8),
                Expanded(
                    child: OutlinedButton(
                        onPressed: busy ? null : () => _go(true),
                        child: const Text('Register'))),
              ]),
            ])));
  }
}

// ── Settings (gear screen) ─────────────────────────────
class SettingsScreen extends StatefulWidget {
  final String themeName;
  final ValueChanged<String> onTheme;
  final VoidCallback onCheckUpdate;
  const SettingsScreen(
      {super.key,
      required this.themeName,
      required this.onTheme,
      required this.onCheckUpdate});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String audio = 'sub';
  bool autoplay = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final p = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        audio = (p.getString('app_audio') ?? 'sub') == 'dub' ? 'dub' : 'sub';
        autoplay = p.getBool('app_autoplay') ?? false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('App settings')),
      body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            const Text('Appearance',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final e in appThemes.entries)
                    ChoiceChip(
                      label: Text(e.value['label'] as String),
                      selected: widget.themeName == e.key,
                      avatar: CircleAvatar(
                          radius: 9,
                          backgroundColor: Color(e.value['seed'] as int)),
                      onSelected: (_) => widget.onTheme(e.key),
                    ),
                ]),
              ),
            ),
            const SizedBox(height: 16),
            const Text('Playback',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Card(
              child: Column(children: [
                ListTile(
                  title: const Text('Default audio',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                  trailing: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'sub', label: Text('SUB')),
                      ButtonSegment(value: 'dub', label: Text('DUB')),
                    ],
                    selected: {audio},
                    onSelectionChanged: (s) async {
                      setState(() => audio = s.first);
                      final p = await SharedPreferences.getInstance();
                      await p.setString('app_audio', s.first);
                    },
                  ),
                ),
                SwitchListTile(
                  title: const Text('Autoplay next episode'),
                  subtitle: const Text('Same as the website focus mode.',
                      style: TextStyle(color: muted, fontSize: 12)),
                  value: autoplay,
                  onChanged: (v) async {
                    setState(() => autoplay = v);
                    final p = await SharedPreferences.getInstance();
                    await p.setBool('app_autoplay', v);
                  },
                ),
              ]),
            ),
            const SizedBox(height: 16),
            const Text('Website connection',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                        color: mint.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12)),
                    child: const Icon(Icons.link, color: mint)),
                title: Text(apiHost,
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                subtitle: const Text(
                    'Built into the app — always on when you have internet. No setup needed.',
                    style: TextStyle(color: muted, fontSize: 12)),
              ),
            ),
            const SizedBox(height: 16),
            const Text('More',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Card(
              child: Column(children: [
                ListTile(
                  leading: const Icon(Icons.tour_outlined, color: amber),
                  title: const Text('Replay app tour',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                  trailing: const Icon(Icons.chevron_right, color: muted),
                  onTap: () async {
                    final p = await SharedPreferences.getInstance();
                    await p.setBool('tutorial_done', false);
                    if (!context.mounted) return;
                    Navigator.pop(context);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.system_update, color: amber),
                  title: Text('Check for updates (v$appVersion)',
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  trailing: const Icon(Icons.chevron_right, color: muted),
                  onTap: widget.onCheckUpdate,
                ),
                const ListTile(
                  leading: Icon(Icons.info_outline, color: muted),
                  title: Text(appCredit),
                  subtitle: Text(
                      'Free forever · SUB & DUB · downloads included',
                      style: TextStyle(color: muted, fontSize: 12)),
                ),
              ]),
            ),
          ]),
    );
  }
}
