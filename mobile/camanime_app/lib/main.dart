import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

// ── Release line ───────────────────────────────────────
const String appVersion = '1.1.0';
const String appCredit = 'Made by kayefande-droid & co.';

// API host is baked at build time (kept out of the repo source):
//   flutter build apk --release --dart-define=CAMANIME_API=https://your-host
// It can still be overridden per-device on the You tab.
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

void main() => runApp(const CamAnimeApp());

class CamAnimeApp extends StatefulWidget {
  const CamAnimeApp({super.key});
  @override
  State<CamAnimeApp> createState() => _CamAnimeAppState();
}

class _CamAnimeAppState extends State<CamAnimeApp> {
  int tab = 0;
  bool showTutorial = false;

  @override
  void initState() {
    super.initState();
    _firstRun();
  }

  Future<void> _firstRun() async {
    final p = await SharedPreferences.getInstance();
    if (p.getBool('tutorial_done') != true) {
      if (mounted) setState(() => showTutorial = true);
    } else {
      _checkUpdate();
    }
  }

  Future<void> _checkUpdate({bool manual = false}) async {
    try {
      final b = await Api.base();
      final r = await http
          .get(Uri.parse('$b/api/version'))
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
              setState(() => tab = 5);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Open the Updates tab to download.')));
            },
            child: const Text('Get it'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CamAnime',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: bg,
        colorScheme: ColorScheme.fromSeed(
            seedColor: brandBlue,
            brightness: Brightness.dark,
            primary: brandBlue),
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
              const DownloadsTab(),
              const LibraryTab(),
              UpdatesTab(onCheck: () => _checkUpdate(manual: true)),
              const ProfileTab(),
            ][tab],
            bottomNavigationBar: NavigationBar(
              backgroundColor: const Color(0xFF0B0E16),
              selectedIndex: tab,
              onDestinationSelected: (i) => setState(() => tab = i),
              destinations: const [
                NavigationDestination(
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home),
                    label: 'Home'),
                NavigationDestination(
                    icon: Icon(Icons.explore_outlined),
                    selectedIcon: Icon(Icons.explore),
                    label: 'Explore'),
                NavigationDestination(
                    icon: Icon(Icons.search_outlined),
                    selectedIcon: Icon(Icons.search),
                    label: 'Search'),
                NavigationDestination(
                    icon: Icon(Icons.download_outlined),
                    selectedIcon: Icon(Icons.download),
                    label: 'Downloads'),
                NavigationDestination(
                    icon: Icon(Icons.video_library_outlined),
                    selectedIcon: Icon(Icons.video_library),
                    label: 'My Library'),
                NavigationDestination(
                    icon: Icon(Icons.system_update_outlined),
                    selectedIcon: Icon(Icons.system_update),
                    label: 'Updates'),
                NavigationDestination(
                    icon: Icon(Icons.person_outline),
                    selectedIcon: Icon(Icons.person),
                    label: 'Profile'),
              ],
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

// ── API (website backend) ──────────────────────────────
class Api {
  static Future<String> base() async {
    final p = await SharedPreferences.getInstance();
    final b = (p.getString('api_base') ?? '').trim();
    return b.isEmpty ? apiHost : b;
  }

  static Future<String?> token() async {
    final p = await SharedPreferences.getInstance();
    return p.getString('api_token');
  }

  static Future<Map<String, String>> headers() async {
    final t = await token();
    return {if (t != null) 'Authorization': 'Bearer $t'};
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
    final b = (await base()).replaceFirst(RegExp(r'/+$'), '');
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
    final b = (await base()).replaceFirst(RegExp(r'/+$'), '');
    final response = await _get(Uri.parse(
        '$b/api/v1/search?q=${Uri.encodeQueryComponent(q)}&limit=36'));
    return ((json.decode(response.body) as Map)['results'] as List?) ?? [];
  }

  static Future<Map<String, dynamic>> animeInfo(String animeId) async {
    final b = (await base()).replaceFirst(RegExp(r'/+$'), '');
    final response = await _get(
        Uri.parse('$b/api/v1/anime/${Uri.encodeComponent(animeId)}'));
    return ((json.decode(response.body) as Map)['anime'] as Map?)
            ?.cast<String, dynamic>() ??
        {};
  }

  static Future<Map<String, dynamic>> announcements() async {
    final b = await base();
    final r = await http
        .get(Uri.parse('$b/api/announcements'))
        .timeout(const Duration(seconds: 12));
    return json.decode(r.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> version() async {
    final b = await base();
    final r = await http
        .get(Uri.parse('$b/api/version'))
        .timeout(const Duration(seconds: 12));
    return json.decode(r.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> signIn(String email, String password,
      {bool register = false, String name = ''}) async {
    final b = await base();
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
    final b = await base();
    try {
      await http.post(Uri.parse('$b/api/auth/logout'),
          headers: await headers());
    } catch (_) {}
    final p = await SharedPreferences.getInstance();
    await p.remove('api_token');
    await p.remove('user_email');
  }

  /// Synced admin/secret status — admin only, same backend the website uses.
  static Future<Map<String, dynamic>> adminSync() async {
    final b = (await base()).replaceFirst(RegExp(r'/+$'), '');
    final r = await http.get(Uri.parse('$b/api/admin/sync'),
        headers: await headers()).timeout(const Duration(seconds: 12));
    final d = json.decode(r.body) as Map<String, dynamic>;
    if (d['status'] != 'success') {
      throw Exception(d['error'] ?? 'Admin sync failed');
    }
    return d;
  }

  /// Change own admin password (admin only). Clears server tokens on success.
  static Future<void> changeAdminPassword(
      String currentPassword, String newPassword) async {
    final b = (await base()).replaceFirst(RegExp(r'/+$'), '');
    final r = await http.post(Uri.parse('$b/api/admin/password'),
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

  /// Download a file directly from the CamAnime platform backend with auth.
  /// Use only for files your platform is authorized to distribute.
  /// Saves into the private in-app library; export via My Library > Save.
  static Future<File> downloadPlatformFile(
      String platformUrl, String filename,
      {void Function(int received, int total)? onProgress}) async {
    final b = (await base()).replaceFirst(RegExp(r'/+$'), '');
    final full = platformUrl.startsWith('http')
        ? platformUrl
        : '$b$platformUrl';
    final req = http.Request('GET', Uri.parse(full));
    req.headers.addAll(await headers());
    final resp = await http.Client().send(req);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException(
          'CamAnime download failed (${resp.statusCode})', uri: Uri.parse(full));
    }
    final dir = await getApplicationSupportDirectory();
    final lib = Directory('${dir.path}/camanime_library');
    await lib.create(recursive: true);
    final safe = filename.replaceAll(RegExp(r'[^a-zA-Z0-9_\-\. ]'), '').trim();
    final file = File('${lib.path}/${safe.isEmpty ? 'CamAnime_File.mp4' : safe}');
    final sink = file.openWrite();
    final total = resp.contentLength ?? 0;
    var received = 0;
    await for (final chunk in resp.stream) {
      received += (chunk as List<int>).length;
      sink.add(chunk);
      onProgress?.call(received, total);
    }
    await sink.close();
    return file;
  }
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
      'Browse AniList-backed catalogue data shared with the CamAnime website.'
    ],
    [
      'Verified availability',
      'Playback and downloads appear only when an authorized source is configured.'
    ],
    [
      'Stay in sync',
      'The catalogue refreshes on return and cached posters remain visible offline.'
    ],
  ];
  @override
  Widget build(BuildContext context) => Container(
        color: Colors.black.withValues(alpha: 0.88),
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [amber, pink]),
                borderRadius: BorderRadius.circular(22)),
            child: const Icon(Icons.play_circle_fill,
                color: Colors.black, size: 44),
          ),
          const SizedBox(height: 18),
          Text(steps[i][0],
              style:
                  const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          Text(steps[i][1],
              textAlign: TextAlign.center,
              style: const TextStyle(color: muted)),
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
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: amber, foregroundColor: Colors.black),
            onPressed: () =>
                i < steps.length - 1 ? setState(() => i++) : widget.onDone(),
            child: Text(i < steps.length - 1 ? 'Next' : 'Start watching'),
          ),
        ]),
      );
}

// ── Home ───────────────────────────────────────────────
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
                ])));
          } else {
            kids.addAll(_homeContent());
          }
          return ListView(padding: EdgeInsets.zero, children: kids);
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

// ── Detail ─────────────────────────────────────────────
class ExploreTab extends StatelessWidget {
  const ExploreTab({super.key});

  @override
  Widget build(BuildContext context) => SafeArea(
          child: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Explore',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
        const SizedBox(height: 8),
        const Text(
            'Browse trending and popular titles. Use Search to filter the shared catalogue.',
            style: TextStyle(color: muted)),
        const SizedBox(height: 14),
        OutlinedButton.icon(
            onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text(
                        'Select Search below to search the live catalogue.'))),
            icon: const Icon(Icons.search),
            label: const Text('Search CamAnime')),
      ]));
}

class DetailScreen extends StatefulWidget {
  final String animeId;
  final String title;
  const DetailScreen({super.key, required this.animeId, required this.title});
  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  Map info = {};
  bool loading = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await Api.animeInfo(widget.animeId);
      if (!mounted) {
        return;
      }
      setState(() {
        info = d;
        loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final poster = (info['image'] ?? '').toString();
    final backdrop = (info['banner'] ?? poster).toString();
    final genres = (info['genres'] as List?) ?? [];
    final episodes = ((info['streaming_metadata'] as List?) ?? []);
    return Scaffold(
      appBar: AppBar(
          title:
              Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: loading
          ? const Center(child: CircularProgressIndicator(color: amber))
          : ListView(padding: EdgeInsets.zero, children: [
              SizedBox(
                  height: 265,
                  child: Stack(fit: StackFit.expand, children: [
                    CachedPosterImage(url: backdrop),
                    const DecoratedBox(
                        decoration: BoxDecoration(
                            gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                          Color(0x22000000),
                          Color(0xFF07080D)
                        ]))),
                    Positioned(
                        left: 18,
                        right: 18,
                        bottom: 16,
                        child: Text((info['title'] ?? widget.title).toString(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 26, fontWeight: FontWeight.w900))),
                  ])),
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
                                        '${info['year'] ?? 'Year unknown'} · ${info['format'] ?? 'Anime'} · ${info['status'] ?? 'Status unknown'}',
                                        style: const TextStyle(
                                            color: muted, fontSize: 12)),
                                    const SizedBox(height: 8),
                                    Text('Rating ${info['rating'] ?? 'N/A'}',
                                        style: const TextStyle(
                                            color: amber,
                                            fontWeight: FontWeight.w700)),
                                    const SizedBox(height: 8),
                                    Text(
                                        info['episode_count'] == null
                                            ? 'Episode count unknown'
                                            : '${info['episode_count']} episodes',
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
                        const SizedBox(height: 18),
                        const Text('Episodes',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 5),
                        Text(
                            episodes.isEmpty
                                ? 'Catalogue information only — no verified episode stream is available here.'
                                : '${episodes.length} episode metadata entries from AniList.',
                            style: const TextStyle(color: muted, fontSize: 12)),
                        const SizedBox(height: 8),
                        if (episodes.isNotEmpty)
                          for (var i = 0; i < episodes.length; i++)
                            Card(
                                child: ListTile(
                              leading:
                                  const Icon(Icons.info_outline, color: muted),
                              title: Text(
                                  episodes[i]['title']?.toString().isNotEmpty ==
                                          true
                                      ? episodes[i]['title'].toString()
                                      : 'Episode information'),
                              subtitle: Text(
                                  (episodes[i]['provider'] ??
                                          'Metadata provider')
                                      .toString(),
                                  style: const TextStyle(
                                      color: muted, fontSize: 12)),
                            )),
                      ])),
            ]),
    );
  }
}

// ── Player (enabled only for authorized source manifests) ──
class PlayerScreen extends StatefulWidget {
  final String label;
  const PlayerScreen({super.key, required this.label});
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Catalogue IDs do not imply playback rights. Only load a server-side,
    // provider-verified manifest if one is configured for the episode.
    if (mounted) {
      setState(() {
        error = 'No authorized streaming source is configured in this build.';
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: Text(widget.label,
                maxLines: 1, overflow: TextOverflow.ellipsis)),
        body: loading
            ? const Center(child: CircularProgressIndicator(color: amber))
            : ListView(padding: const EdgeInsets.all(16), children: [
                Container(
                  decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      color: Colors.black),
                  clipBehavior: Clip.antiAlias,
                  child: const AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Center(
                        child:
                            Icon(Icons.play_disabled, color: muted, size: 42)),
                  ),
                ),
                const SizedBox(height: 10),
                if (error != null)
                  Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: muted))),
                const Text(appCredit,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: muted, fontSize: 12)),
              ]),
      );
}

// ── Search (posters, full catalog) ─────────────────────
class SearchTab extends StatefulWidget {
  const SearchTab({super.key});
  @override
  State<SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<SearchTab> {
  final c = TextEditingController();
  List results = [];
  bool loading = false;

  Timer? _debounce;
  int _requestId = 0;
  String? error;

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
        results = [];
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
          if (loading) const LinearProgressIndicator(color: amber),
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
                    padding: const EdgeInsets.all(16),
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

// ── Library (hidden in-app, save-to-device export) ─────
class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key});
  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class DownloadsTab extends StatefulWidget {
  const DownloadsTab({super.key});
  @override
  State<DownloadsTab> createState() => _DownloadsTabState();
}

class _DownloadsTabState extends State<DownloadsTab> {
  final _urlCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  bool _busy = false;
  double? _progress;
  String _status = 'Sign in first, then paste a CamAnime platform file link.';

  Future<void> _download() async {
    final url = _urlCtrl.text.trim();
    final name = _nameCtrl.text.trim().isEmpty ? 'CamAnime_File.mp4' : _nameCtrl.text.trim();
    if (url.isEmpty) {
      setState(() => _status = 'Paste a CamAnime /api/download/video link first.');
      return;
    }
    setState(() {
      _busy = true;
      _progress = 0;
      _status = 'Downloading directly from your CamAnime platform…';
    });
    try {
      final f = await Api.downloadPlatformFile(url, name,
          onProgress: (rec, total) {
        if (mounted && total > 0) setState(() => _progress = rec / total);
      });
      if (mounted) {
        setState(() => _status = 'Saved to My Library: ${f.uri.pathSegments.last}');
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Saved to My Library')));
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Download failed: $e');
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _progress = null;
      });
    }
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
          child: ListView(padding: const EdgeInsets.all(20), children: [
        const Text('Downloads',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
        const SizedBox(height: 6),
        const Text(
            'Downloads come directly from your CamAnime platform. Sign in, paste a platform file link, and keep it in My Library. Only download files your platform is authorized to distribute.',
            style: TextStyle(color: muted, fontSize: 12)),
        const SizedBox(height: 12),
        TextField(
            controller: _urlCtrl,
            decoration: const InputDecoration(
                labelText: 'CamAnime file link',
                hintText: '/api/download/video?url=...&title=...',
                border: OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
                labelText: 'Save as (optional)',
                hintText: 'My_Episode.mp4',
                border: OutlineInputBorder()),
        ),
        const SizedBox(height: 10),
        FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: amber, foregroundColor: Colors.black),
            onPressed: _busy ? null : _download,
            child: Text(_busy ? 'Downloading…' : 'Download from CamAnime')),
        if (_progress != null) ...[
          const SizedBox(height: 10),
          LinearProgressIndicator(value: _progress, color: amber),
        ],
        const SizedBox(height: 10),
        Card(
            child: ListTile(
                leading: const Icon(Icons.info_outline, color: muted),
                title: Text(_status),
                subtitle: const Text(
                    'Files stay in the private in-app library until you tap Save in My Library.',
                    style: TextStyle(color: muted)))),
      ]));
}

class _LibraryTabState extends State<LibraryTab> {
  List<FileSystemEntity> files = [];
  @override
  void initState() {
    super.initState();
    _load();
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
    setState(() => files = lib.listSync().whereType<File>().toList());
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

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('My Library',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
            const Text('Hidden in-app — nothing leaves until you tap Save.',
                style: TextStyle(color: muted, fontSize: 12)),
            const SizedBox(height: 10),
            Expanded(
              child: files.isEmpty
                  ? const Center(
                      child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                          Icon(Icons.video_library_outlined,
                              size: 64, color: muted),
                          SizedBox(height: 10),
                          Text('No downloads yet',
                              style: TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.w800)),
                          Text('Download from any player screen.',
                              style: TextStyle(color: muted)),
                        ]))
                  : ListView.builder(
                      itemCount: files.length,
                      itemBuilder: (_, i) {
                        final f = files[i] as File;
                        return Card(
                          margin: const EdgeInsets.only(bottom: 10),
                          child: ListTile(
                            leading: Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                    color: purple.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(12)),
                                child: const Icon(Icons.movie, color: purple)),
                            title: Text(f.uri.pathSegments.last,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                            trailing: FilledButton(
                                style: FilledButton.styleFrom(
                                    backgroundColor: amber,
                                    foregroundColor: Colors.black),
                                onPressed: () => _saveToDevice(f),
                                child: const Text('Save')),
                          ),
                        );
                      }),
            ),
          ]),
        ),
      );
}

// ── Updates (version check + CEO announcements) ─────────
class UpdatesTab extends StatefulWidget {
  final VoidCallback onCheck;
  const UpdatesTab({super.key, required this.onCheck});
  @override
  State<UpdatesTab> createState() => _UpdatesTabState();
}

class _UpdatesTabState extends State<UpdatesTab> {
  List ann = [];
  Map ver = {};
  bool busy = false;
  double? progress;

  Future<void> _load() async {
    try {
      final a = await Api.announcements();
      final v = await Api.version();
      if (!mounted) {
        return;
      }
      setState(() {
        ann = (a['announcements'] as List?) ?? [];
        ver = v;
      });
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _downloadUpdate() async {
    setState(() {
      busy = true;
      progress = 0;
    });
    try {
      final b = await Api.base();
      final req = http.Request('GET', Uri.parse('$b/get/android'));
      final resp = await http.Client().send(req);
      final total = resp.contentLength ?? 0;
      final bytes = <int>[];
      await for (final chunk in resp.stream) {
        bytes.addAll(chunk);
        if (mounted && total > 0) {
          setState(() => progress = bytes.length / total);
        }
      }
      final dir = await getDownloadsDirectory() ??
          await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/CamAnime-update.apk');
      await f.writeAsBytes(bytes);
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
      child: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Updates',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
        Text('This app: v$appVersion',
            style: const TextStyle(color: muted, fontSize: 12)),
        const SizedBox(height: 10),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.system_update, color: amber),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(
                        hasUpdate
                            ? 'Version $latest is available'
                            : 'You are up to date',
                        style: const TextStyle(fontWeight: FontWeight.w800))),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: amber,
                          foregroundColor: Colors.black),
                      onPressed: busy ? null : _downloadUpdate,
                      child: Text(busy ? 'Downloading…' : 'Download update')),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                    onPressed: widget.onCheck, child: const Text('Check')),
              ]),
              if (progress != null) ...[
                const SizedBox(height: 10),
                LinearProgressIndicator(value: progress, color: amber),
              ],
            ]),
          ),
        ),
        const SizedBox(height: 12),
        const Text('Announcements from kayefande-droid & co.',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        if (ann.isEmpty)
          const Card(
              child: ListTile(
                  title: Text('No announcements yet.',
                      style: TextStyle(color: muted))))
        else
          for (final a in ann)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: const Icon(Icons.campaign, color: amber),
                title: Text((a['title'] ?? '').toString(),
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                subtitle: Text((a['body'] ?? '').toString()),
              ),
            ),
      ]),
    );
  }
}

// ── You (link, optional auth — watching needs no login) ─
class ProfileTab extends StatefulWidget {
  const ProfileTab({super.key});
  @override
  State<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<ProfileTab> {
  final base = TextEditingController();
  final name = TextEditingController();
  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final p = await SharedPreferences.getInstance();
    base.text = p.getString('api_base') ?? '';
    name.text = p.getString('username') ?? '';
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) =>
      ListView(padding: EdgeInsets.zero, children: [
        Container(
          padding: const EdgeInsets.fromLTRB(20, 52, 20, 18),
          decoration: const BoxDecoration(
              gradient: LinearGradient(
                  colors: [Color(0xFF1A1033), bg],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight)),
          child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('You',
                    style:
                        TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                Text(
                    'Watching is free without an account. Sign in to sync downloads, ratings and forums.',
                    style: TextStyle(color: muted, fontSize: 12)),
              ]),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(children: [
                  const CircleAvatar(
                      radius: 34,
                      backgroundColor: Color(0x33FFB347),
                      child: Icon(Icons.person, size: 38, color: amber)),
                  const SizedBox(height: 8),
                  TextField(
                      controller: name,
                      decoration: const InputDecoration(
                          labelText: 'Username',
                          prefixIcon: Icon(Icons.badge_outlined))),
                  const SizedBox(height: 8),
                  TextField(
                      controller: base,
                      decoration: const InputDecoration(
                          labelText: 'Website URL (blank = built-in default)',
                          prefixIcon: Icon(Icons.link))),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                        style: FilledButton.styleFrom(
                            backgroundColor: amber,
                            foregroundColor: Colors.black),
                        onPressed: () async {
                          final p = await SharedPreferences.getInstance();
                          await p.setString('api_base', base.text.trim());
                          await p.setString('username', name.text.trim());
                          if (!context.mounted) return;
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content:
                                        Text('Linked to website backend')));
                          }
                        },
                        child: const Text('Save & link app to website')),
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
      ]);
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
