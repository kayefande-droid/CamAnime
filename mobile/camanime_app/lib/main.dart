import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';

// ── Release line ───────────────────────────────────────
const String APP_VERSION = '1.0.0';
const String APP_CREDIT = 'Made by kayefande-droid & co.';

// API host is baked at build time (kept out of the repo source):
//   flutter build apk --release --dart-define=CAMANIME_API=https://your-host
// It can still be overridden per-device on the You tab.
const String API_HOST = String.fromEnvironment(
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
      final r = await http.get(Uri.parse('$b/api/version')).timeout(const Duration(seconds: 12));
      final d = json.decode(r.body) as Map<String, dynamic>;
      final latest = (d['app_version'] ?? '').toString();
      if (latest.isNotEmpty && latest != APP_VERSION && mounted) {
        _updateDialog(latest);
      } else if (manual && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('You are on the latest version ($APP_VERSION)')));
      }
    } catch (_) {
      if (manual && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not reach the website — check internet.')));
      }
    }
  }

  void _updateDialog(String latest) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: card,
        title: Text('Update available: $latest'),
        content: const Text('A newer CamAnime is on the website. Download it now? Watching stays free, no login needed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Later')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: amber, foregroundColor: Colors.black),
            onPressed: () {
              Navigator.pop(context);
              setState(() => tab = 3);
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Open the Updates tab to download.')));
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
        colorScheme: ColorScheme.fromSeed(seedColor: amber, brightness: Brightness.dark, primary: amber),
        cardTheme: CardThemeData(color: card, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
        inputDecorationTheme: InputDecorationTheme(
          filled: true, fillColor: card2,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
          hintStyle: const TextStyle(color: muted),
        ),
      ),
      home: Stack(
        children: [
          Scaffold(
            body: [
              HomeTab(onUpdate: () => _checkUpdate(manual: true)),
              const SearchTab(),
              const LibraryTab(),
              UpdatesTab(onCheck: () => _checkUpdate(manual: true)),
              const ProfileTab(),
            ][tab],
            bottomNavigationBar: NavigationBar(
              backgroundColor: const Color(0xFF0B0E16),
              selectedIndex: tab,
              onDestinationSelected: (i) => setState(() => tab = i),
              destinations: const [
                NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
                NavigationDestination(icon: Icon(Icons.search_outlined), selectedIcon: Icon(Icons.search), label: 'Search'),
                NavigationDestination(icon: Icon(Icons.video_library_outlined), selectedIcon: Icon(Icons.video_library), label: 'Library'),
                NavigationDestination(icon: Icon(Icons.system_update_outlined), selectedIcon: Icon(Icons.system_update), label: 'Updates'),
                NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'You'),
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
    return b.isEmpty ? API_HOST : b;
  }

  static Future<String?> token() async {
    final p = await SharedPreferences.getInstance();
    return p.getString('api_token');
  }

  static Future<Map<String, String>> headers() async {
    final t = await token();
    return {if (t != null) 'Authorization': 'Bearer $t'};
  }

  static Future<List> catalog(String feed) async {
    final b = await base();
    final r = await http.get(Uri.parse('$b/api/heaven/catalog?feed=$feed')).timeout(const Duration(seconds: 20));
    return ((json.decode(r.body) as Map)['results'] as List?) ?? [];
  }

  static Future<List> search(String q) async {
    final b = await base();
    final r = await http.get(Uri.parse('$b/api/heaven/search?q=${Uri.encodeComponent(q)}')).timeout(const Duration(seconds: 20));
    return ((json.decode(r.body)['results'] as List?) ?? []);
  }

  static Future<Map<String, dynamic>> animeInfo(String siteId) async {
    final b = await base();
    final r = await http.get(Uri.parse('$b/api/heaven/anime/${Uri.encodeComponent(siteId)}')).timeout(const Duration(seconds: 20));
    return (json.decode(r.body)['anime'] as Map<String, dynamic>?) ?? {};
  }

  static Future<List> resolveSources(String key, String siteId) async {
    final b = await base();
    final r = await http.get(Uri.parse('$b/api/heaven/resolve/${Uri.encodeComponent(key)}?site_id=${Uri.encodeComponent(siteId)}')).timeout(const Duration(seconds: 25));
    final d = json.decode(r.body) as Map<String, dynamic>;
    return (d['sources'] as List?) ?? [];
  }

  static Future<Map<String, dynamic>> announcements() async {
    final b = await base();
    final r = await http.get(Uri.parse('$b/api/announcements')).timeout(const Duration(seconds: 12));
    return json.decode(r.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> version() async {
    final b = await base();
    final r = await http.get(Uri.parse('$b/api/version')).timeout(const Duration(seconds: 12));
    return json.decode(r.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> signIn(String email, String password, {bool register = false, String name = ''}) async {
    final b = await base();
    final path = register ? 'register' : 'login';
    final r = await http.post(Uri.parse('$b/api/auth/$path'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'email': email, 'password': password, 'name': name}));
    final d = json.decode(r.body) as Map<String, dynamic>;
    if (d['status'] != 'success') throw Exception(d['error'] ?? 'Sign-in failed');
    final p = await SharedPreferences.getInstance();
    await p.setString('api_token', d['token']);
    await p.setString('user_email', (d['user'] as Map)['email']);
    await p.setString('username', (d['user'] as Map)['name']);
    return d['user'] as Map<String, dynamic>;
  }

  static Future<void> signOut() async {
    final b = await base();
    try {
      await http.post(Uri.parse('$b/api/auth/logout'), headers: await headers());
    } catch (_) {}
    final p = await SharedPreferences.getInstance();
    await p.remove('api_token');
    await p.remove('user_email');
  }
}

// ── Shared widgets ─────────────────────────────────────
class PosterCard extends StatelessWidget {
  final Map item;
  final double width;
  const PosterCard({super.key, required this.item, this.width = 128});
  @override
  Widget build(BuildContext context) {
    final img = (item['image'] ?? '').toString();
    return GestureDetector(
      onTap: () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => DetailScreen(siteId: item['id'].toString(), title: (item['title'] ?? '').toString()))),
      child: SizedBox(
        width: width,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: AspectRatio(
              aspectRatio: 2 / 2.85,
              child: img.isEmpty
                  ? Container(color: card2, child: const Icon(Icons.movie, color: muted))
                  : Image.network(img, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(color: card2, child: const Icon(Icons.broken_image, color: muted))),
            ),
          ),
          const SizedBox(height: 6),
          Text((item['title'] ?? 'Unknown').toString(),
              maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }
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
    ['Find anime', 'Search the full catalog — classics included. Watching is free, no account needed.'],
    ['Stream or save', 'Play 1080p SUB/DUB in the app, or download into the hidden library.'],
    ['Take it with you', 'Files stay inside the app until you tap Save to device. Updates tab keeps you current.'],
  ];
  @override
  Widget build(BuildContext context) => Container(
        color: Colors.black.withOpacity(0.88),
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(gradient: const LinearGradient(colors: [amber, pink]), borderRadius: BorderRadius.circular(22)),
            child: const Icon(Icons.play_circle_fill, color: Colors.black, size: 44),
          ),
          const SizedBox(height: 18),
          Text(steps[i][0], style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          Text(steps[i][1], textAlign: TextAlign.center, style: const TextStyle(color: muted)),
          const SizedBox(height: 20),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var k = 0; k < steps.length; k++)
              Container(margin: const EdgeInsets.symmetric(horizontal: 4), width: i == k ? 26 : 8, height: 8,
                  decoration: BoxDecoration(color: i == k ? amber : muted, borderRadius: BorderRadius.circular(99))),
          ]),
          const SizedBox(height: 20),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: amber, foregroundColor: Colors.black),
            onPressed: () => i < steps.length - 1 ? setState(() => i++) : widget.onDone(),
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

class _HomeTabState extends State<HomeTab> {
  List popular = [], fresh = [], ann = [];
  bool loading = true;
  String? err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([Api.catalog('popular'), Api.catalog('new'), Api.announcements()]);
      if (!mounted) return;
      setState(() {
        popular = results[0] as List;
        fresh = results[1] as List;
        ann = ((results[2] as Map)['announcements'] as List?) ?? [];
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        err = 'No internet — connect and pull to retry. The app streams from the website.';
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
          if (loading) {
            kids.add(const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator(color: amber))));
          } else if (err != null) {
            kids.add(Padding(
                padding: const EdgeInsets.all(24),
                child: Column(children: [
                  const Icon(Icons.wifi_off, size: 48, color: muted),
                  const SizedBox(height: 8),
                  Text(err!, textAlign: TextAlign.center, style: const TextStyle(color: muted)),
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
            gradient: LinearGradient(colors: [Color(0xFF1A1033), bg], begin: Alignment.topLeft, end: Alignment.bottomRight)),
        child: Row(children: [
          Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(gradient: const LinearGradient(colors: [amber, pink]), borderRadius: BorderRadius.circular(14)),
              child: const Icon(Icons.play_circle_fill, color: Colors.black, size: 26)),
          const SizedBox(width: 12),
          const Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('CamAnime', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
            Text('Free 1080p SUB + DUB · v$APP_VERSION', style: TextStyle(color: muted, fontSize: 12)),
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
          title: Text((ann.first['title'] ?? '').toString(), style: const TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Text((ann.first['body'] ?? '').toString(), maxLines: 2, overflow: TextOverflow.ellipsis),
        )),
      ));
    }
    out.add(_rail('Popular now', popular));
    out.add(_rail('Fresh releases', fresh));
    out.add(const Padding(
        padding: EdgeInsets.all(16),
        child: Text(APP_CREDIT, textAlign: TextAlign.center, style: TextStyle(color: muted, fontSize: 12))));
    return out;
  }

  Widget _rail(String title, List items) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
        SizedBox(
          height: 236,
          child: items.isEmpty
              ? const Center(child: Text('Nothing here yet — pull to refresh.', style: TextStyle(color: muted)))
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
class DetailScreen extends StatefulWidget {
  final String siteId;
  final String title;
  const DetailScreen({super.key, required this.siteId, required this.title});
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
      final d = await Api.animeInfo(widget.siteId);
      if (!mounted) return;
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
    final eps = (info['episodes'] as List?) ?? [];
    final poster = (info['poster'] ?? '').toString();
    return Scaffold(
      appBar: AppBar(title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: loading
          ? const Center(child: CircularProgressIndicator(color: amber))
          : ListView(padding: const EdgeInsets.all(16), children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: SizedBox(
                    width: 120,
                    child: AspectRatio(
                      aspectRatio: 2 / 2.85,
                      child: poster.isEmpty
                          ? Container(color: card2, child: const Icon(Icons.movie, color: muted))
                          : Image.network(poster, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(color: card2, child: const Icon(Icons.broken_image, color: muted))),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text((info['title'] ?? widget.title).toString(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                  if ((info['title_jp'] ?? '').toString().isNotEmpty)
                    Text(info['title_jp'].toString(), style: const TextStyle(color: muted, fontSize: 12)),
                  const SizedBox(height: 6),
                  Text('${eps.length} episodes • SUB + DUB', style: const TextStyle(color: mint, fontSize: 12)),
                ])),
              ]),
              if ((info['description'] ?? '').toString().isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(info['description'].toString(), maxLines: 4, overflow: TextOverflow.ellipsis, style: const TextStyle(color: muted, fontSize: 13)),
              ],
              const SizedBox(height: 12),
              const Text('Episodes', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              if (eps.isEmpty)
                const Text('No episodes listed — try on the website.', style: TextStyle(color: muted))
              else
                for (final e in eps)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(color: amber.withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
                          child: const Icon(Icons.play_arrow, color: amber)),
                      title: Text('Episode ${(e['num'] ?? '?').toString()}', style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text((e['title'] ?? '').toString(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: muted, fontSize: 12)),
                      trailing: const Icon(Icons.chevron_right, color: muted),
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => PlayerScreen(
                                  siteId: widget.siteId,
                                  epKey: (e['key'] ?? '').toString(),
                                  label: 'Ep ${e['num']} • ${(info['title'] ?? widget.title).toString()}'))),
                    ),
                  ),
            ]),
    );
  }
}

// ── Player (heaven direct sources, no login needed) ────
class PlayerScreen extends StatefulWidget {
  final String siteId;
  final String epKey;
  final String label;
  const PlayerScreen({super.key, required this.siteId, required this.epKey, required this.label});
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  VideoPlayerController? vc;
  ChewieController? cc;
  List sources = [];
  Map? active;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<String> _absUrl(String u) async {
    if (u.startsWith('http')) return u;
    return '${await Api.base()}$u';
  }

  Future<void> _play(Map s) async {
    await vc?.pause();
    cc?.dispose();
    vc?.dispose();
    vc = null;
    cc = null;
    final raw = (s['proxy_url'] ?? s['url'] ?? '').toString();
    if (raw.isEmpty) return;
    try {
      vc = VideoPlayerController.networkUrl(Uri.parse(await _absUrl(raw)));
      await vc!.initialize();
      if (!mounted) return;
      cc = ChewieController(videoPlayerController: vc!, autoPlay: true, allowMuting: true, allowFullScreen: true);
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      sources = await Api.resolveSources(widget.epKey, widget.siteId);
      if (sources.isNotEmpty) {
        active = sources.first;
        await _play(active!);
      }
    } catch (_) {}
    if (mounted) setState(() => loading = false);
  }

  Future<void> _downloadActive() async {
    final tok = await Api.token();
    if (tok == null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Optional: sign in on the You tab to unlock downloads.')));
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Saved into the hidden in-app library.')));
    }
  }

  @override
  void dispose() {
    vc?.dispose();
    cc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis)),
        body: loading
            ? const Center(child: CircularProgressIndicator(color: amber))
            : ListView(padding: const EdgeInsets.all(16), children: [
                Container(
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), color: Colors.black),
                  clipBehavior: Clip.antiAlias,
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: cc != null
                        ? Chewie(controller: cc!)
                        : const Center(child: Text('Could not load a stream — try another source.', style: TextStyle(color: muted))),
                  ),
                ),
                const SizedBox(height: 10),
                for (final s in sources)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    color: identical(s, active) ? const Color(0xFF1B2133) : card,
                    child: ListTile(
                      leading: const Icon(Icons.play_circle_fill, color: amber, size: 30),
                      title: Text((s['quality'] ?? s['server'] ?? 'Source').toString(), style: const TextStyle(fontWeight: FontWeight.w700)),
                      trailing: identical(s, active) ? const Icon(Icons.check_circle, color: mint) : null,
                      onTap: () async {
                        setState(() {
                          active = s;
                          loading = true;
                        });
                        await _play(s);
                        setState(() => loading = false);
                      },
                    ),
                  ),
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: amber, foregroundColor: Colors.black),
                      onPressed: _downloadActive,
                      child: const Text('Download to hidden library', style: TextStyle(fontWeight: FontWeight.w900))),
                ),
                const SizedBox(height: 10),
                const Text(APP_CREDIT, textAlign: TextAlign.center, style: TextStyle(color: muted, fontSize: 12)),
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

  Future<void> go() async {
    if (c.text.trim().length < 2) return;
    setState(() => loading = true);
    try {
      results = await Api.search(c.text.trim());
    } catch (_) {
      results = [];
    }
    if (mounted) setState(() => loading = false);
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
                  onSubmitted: (_) => go(),
                  decoration: const InputDecoration(hintText: 'Search every anime…', prefixIcon: Icon(Icons.search)),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                decoration: BoxDecoration(gradient: const LinearGradient(colors: [amber, pink]), borderRadius: BorderRadius.circular(14)),
                child: IconButton(icon: const Icon(Icons.arrow_forward, color: Colors.black), onPressed: go),
              ),
            ]),
          ),
          if (loading) const LinearProgressIndicator(color: amber),
          Expanded(
            child: results.isEmpty
                ? const Center(
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.search_rounded, size: 56, color: muted),
                    SizedBox(height: 8),
                    Text('Old classics included — just type.', style: TextStyle(color: muted)),
                  ]))
                : GridView.builder(
                    padding: const EdgeInsets.all(16),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3, childAspectRatio: 0.52, crossAxisSpacing: 10, mainAxisSpacing: 12),
                    itemCount: results.length,
                    itemBuilder: (_, i) => PosterCard(item: results[i] as Map, width: double.infinity),
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
    if (!await lib.exists()) await lib.create(recursive: true);
    if (!mounted) return;
    setState(() => files = lib.listSync().whereType<File>().toList());
  }

  Future<void> _saveToDevice(File f) async {
    try {
      final pub = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
      await f.copy('${pub.path}/${f.uri.pathSegments.last}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved to device Downloads')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('My Library', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
            const Text('Hidden in-app — nothing leaves until you tap Save.', style: TextStyle(color: muted, fontSize: 12)),
            const SizedBox(height: 10),
            Expanded(
              child: files.isEmpty
                  ? const Center(
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(Icons.video_library_outlined, size: 64, color: muted),
                      SizedBox(height: 10),
                      Text('No downloads yet', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                      Text('Download from any player screen.', style: TextStyle(color: muted)),
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
                                decoration: BoxDecoration(color: purple.withOpacity(0.15), borderRadius: BorderRadius.circular(12)),
                                child: const Icon(Icons.movie, color: purple)),
                            title: Text(f.uri.pathSegments.last, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                            trailing: FilledButton(
                                style: FilledButton.styleFrom(backgroundColor: amber, foregroundColor: Colors.black),
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
      if (!mounted) return;
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
        if (mounted && total > 0) setState(() => progress = bytes.length / total);
      }
      final dir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/CamAnime-update.apk');
      await f.writeAsBytes(bytes);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Update saved to Downloads — open CamAnime-update.apk to install.')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Download failed — check internet.')));
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
    final hasUpdate = latest.isNotEmpty && latest != APP_VERSION;
    return SafeArea(
      child: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Updates', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
        Text('This app: v$APP_VERSION', style: const TextStyle(color: muted, fontSize: 12)),
        const SizedBox(height: 10),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.system_update, color: amber),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(hasUpdate ? 'Version $latest is available' : 'You are up to date',
                        style: const TextStyle(fontWeight: FontWeight.w800))),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: amber, foregroundColor: Colors.black),
                      onPressed: busy ? null : _downloadUpdate,
                      child: Text(busy ? 'Downloading…' : 'Download update')),
                ),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: widget.onCheck, child: const Text('Check')),
              ]),
              if (progress != null) ...[
                const SizedBox(height: 10),
                LinearProgressIndicator(value: progress, color: amber),
              ],
            ]),
          ),
        ),
        const SizedBox(height: 12),
        const Text('Announcements from kayefande-droid & co.', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        if (ann.isEmpty)
          const Card(child: ListTile(title: Text('No announcements yet.', style: TextStyle(color: muted))))
        else
          for (final a in ann)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: const Icon(Icons.campaign, color: amber),
                title: Text((a['title'] ?? '').toString(), style: const TextStyle(fontWeight: FontWeight.w800)),
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
  Widget build(BuildContext context) => ListView(padding: EdgeInsets.zero, children: [
        Container(
          padding: const EdgeInsets.fromLTRB(20, 52, 20, 18),
          decoration: const BoxDecoration(
              gradient: LinearGradient(colors: [Color(0xFF1A1033), bg], begin: Alignment.topLeft, end: Alignment.bottomRight)),
          child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('You', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
            Text('Watching is free without an account. Sign in to sync downloads, ratings and forums.', style: TextStyle(color: muted, fontSize: 12)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(children: [
                  const CircleAvatar(radius: 34, backgroundColor: Color(0x33FFB347), child: Icon(Icons.person, size: 38, color: amber)),
                  const SizedBox(height: 8),
                  TextField(controller: name, decoration: const InputDecoration(labelText: 'Username', prefixIcon: Icon(Icons.badge_outlined))),
                  const SizedBox(height: 8),
                  TextField(
                      controller: base,
                      decoration: const InputDecoration(
                          labelText: 'Website URL (blank = built-in default)', prefixIcon: Icon(Icons.link))),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: amber, foregroundColor: Colors.black),
                        onPressed: () async {
                          final p = await SharedPreferences.getInstance();
                          await p.setString('api_base', base.text.trim());
                          await p.setString('username', name.text.trim());
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Linked to website backend')));
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
            const Text(APP_CREDIT, textAlign: TextAlign.center, style: TextStyle(color: muted, fontSize: 12)),
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
    if (!mounted) return;
    setState(() => who = p.getString('user_email'));
  }

  Future<void> _go(bool register) async {
    setState(() => busy = true);
    try {
      final u = await Api.signIn(email.text.trim(), password.text, register: register, name: email.text.split('@').first);
      if (!mounted) return;
      setState(() => who = u['email'] as String?);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Signed in as ${u['email']} — synced with website')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
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
            decoration: BoxDecoration(color: mint.withOpacity(0.15), borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.verified_user, color: mint)),
        title: Text(who!, style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: const Text('Synced with the website database', style: TextStyle(color: muted, fontSize: 12)),
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
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Account (optional)', style: TextStyle(fontWeight: FontWeight.w800)),
              const Text('Same permanent database as the site.', style: TextStyle(color: muted, fontSize: 12)),
              const SizedBox(height: 10),
              TextField(
                  controller: email, keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Email (Gmail / iCloud)', prefixIcon: Icon(Icons.email_outlined))),
              const SizedBox(height: 8),
              TextField(controller: password, obscureText: true, decoration: const InputDecoration(labelText: 'Password', prefixIcon: Icon(Icons.lock_outline))),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                    child: FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: amber, foregroundColor: Colors.black),
                        onPressed: busy ? null : () => _go(false),
                        child: Text(busy ? 'Please wait…' : 'Sign in'))),
                const SizedBox(width: 8),
                Expanded(child: OutlinedButton(onPressed: busy ? null : () => _go(true), child: const Text('Register'))),
              ]),
            ])));
  }
}
