import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';

const String API_BASE_DEFAULT = 'https://your-camanime-host';
const APP_CREDIT = 'Made by kayefande-droid & co.';

// ── Brand ──────────────────────────────────────────────
const bg = Color(0xFF07080D);
const card = Color(0xFF0E111A);
const card2 = Color(0xFF141926);
const amber = Color(0xFFFFB347);
const purple = Color(0xFF7C61D4);
const pink = Color(0xFFFF5E62);
const mint = Color(0xFF10B981);
const muted = Color(0xFFA0ABC0);

void main() => runApp(const CamAnimeApp());

class CamAnimeApp extends StatefulWidget {
  const CamAnimeApp({super.key});
  @override
  State<CamAnimeApp> createState() => _CamAnimeAppState();
}

class _CamAnimeAppState extends State<CamAnimeApp> {
  ThemeMode mode = ThemeMode.dark;
  int tab = 0;
  @override
  Widget build(BuildContext context) {
    final dark = ThemeData.dark(useMaterial3: true).copyWith(
      scaffoldBackgroundColor: bg,
      colorScheme: ColorScheme.fromSeed(
          seedColor: amber, brightness: Brightness.dark, primary: amber),
      cardTheme: CardThemeData(
          color: card,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: card2,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none),
        hintStyle: const TextStyle(color: muted),
      ),
      navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Color(0xFF0B0E16),
          indicatorColor: Color(0x33FFB347)),
    );
    final light = ThemeData(useMaterial3: true).copyWith(
      colorScheme: ColorScheme.fromSeed(seedColor: purple),
      cardTheme: CardThemeData(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
    );
    return MaterialApp(
      title: 'CamAnime',
      debugShowCheckedModeBanner: false,
      themeMode: mode,
      theme: light,
      darkTheme: dark,
      home: Scaffold(
        body: [const HomeTab(), const SearchTab(), const LibraryTab(), const ProfileTab()][tab],
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) => setState(() => tab = i),
          destinations: const [
            NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home),
                label: 'Home'),
            NavigationDestination(
                icon: Icon(Icons.search_outlined),
                selectedIcon: Icon(Icons.search),
                label: 'Search'),
            NavigationDestination(
                icon: Icon(Icons.video_library_outlined),
                selectedIcon: Icon(Icons.video_library),
                label: 'Library'),
            NavigationDestination(
                icon: Icon(Icons.person_outline),
                selectedIcon: Icon(Icons.person),
                label: 'You'),
          ],
        ),
      ),
    );
  }
}

class Api {
  static Future<String> base() async {
    final p = await SharedPreferences.getInstance();
    return p.getString('api_base') ?? API_BASE_DEFAULT;
  }

  static Future<String?> token() async {
    final p = await SharedPreferences.getInstance();
    return p.getString('api_token');
  }

  static Future<Map<String, String>> headers() async {
    final t = await token();
    return {if (t != null) 'Authorization': 'Bearer $t'};
  }

  static Future<Map<String, dynamic>> episodeSources(int id, int ep) async {
    final b = await base();
    final r = await http.get(Uri.parse('$b/api/public/anime/$id?ep=$ep'),
        headers: await headers());
    return json.decode(r.body) as Map<String, dynamic>;
  }

  /// Sign in (or register) against the website's permanent user database.
  static Future<Map<String, dynamic>> signIn(String email, String password,
      {bool register = false, String name = ''}) async {
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
      await http.post(Uri.parse('$b/api/auth/logout'),
          headers: await headers());
    } catch (_) {}
    final p = await SharedPreferences.getInstance();
    await p.remove('api_token');
    await p.remove('user_email');
  }
}

// ── Shared bits ────────────────────────────────────────
class GradientHeader extends StatelessWidget {
  final String title;
  final String sub;
  final bool showThemeToggle;
  final VoidCallback? onThemeToggle;
  final bool dark;
  const GradientHeader(
      {super.key,
      required this.title,
      required this.sub,
      this.showThemeToggle = false,
      this.onThemeToggle,
      this.dark = true});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 52, 20, 20),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF1A1033), Color(0xFF07080D)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [amber, pink]),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.play_circle_fill,
                color: Colors.black, size: 26),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w900)),
                  Text(sub,
                      style:
                          const TextStyle(color: muted, fontSize: 12)),
                ]),
          ),
          if (showThemeToggle)
            IconButton(
              icon: Icon(dark ? Icons.light_mode : Icons.dark_mode,
                  color: amber),
              onPressed: onThemeToggle,
            ),
        ],
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String text;
  final String? action;
  const SectionTitle({super.key, required this.text, this.action});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 10),
        child: Row(
          children: [
            Text(text,
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w800)),
            const Spacer(),
            if (action != null)
              const Text('See all',
                  style: TextStyle(color: amber, fontSize: 12)),
          ],
        ),
      );
}

// ── Home ───────────────────────────────────────────────
class HomeTab extends StatelessWidget {
  const HomeTab({super.key});

  static const picks = [
    {'id': 113415, 't': 'Jujutsu Kaisen', 'e': '🍥 Sorcery • Action', 'g1': purple, 'g2': pink},
    {'id': 21, 't': 'One Piece', 'e': '🏴‍☠️ Long-running • Adventure', 'g1': amber, 'g2': pink},
    {'id': 20, 't': 'Naruto', 'e': '🍜 Classic • Ninja', 'g1': mint, 'g2': purple},
    {'id': 16498, 't': 'Attack on Titan', 'e': '⚔️ Dark • Epic', 'g1': Color(0xFF334155), 'g2': pink},
    {'id': 1535, 't': 'Death Note', 'e': '📓 Thriller • Mind games', 'g1': Color(0xFF1E1B4B), 'g2': purple},
    {'id': 101922, 't': 'Demon Slayer', 'e': '🔥 Sword • Stunning fights', 'g1': pink, 'g2': amber},
    {'id': 22297, 't': 'Frieren', 'e': '🌸 Calm • Fantasy', 'g1': mint, 'g2': Color(0xFF0EA5E9)},
    {'id': 182765, 't': 'Solo Leveling', 'e': '👾 Action • Hunter', 'g1': purple, 'g2': Color(0xFF0EA5E9)},
  ];

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        const GradientHeader(
            title: 'CamAnime', sub: 'Free 1080p SUB + DUB • no account needed'),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _heroCard(context),
                const SectionTitle(text: '🔥 Trending now', action: 'x'),
                for (final a in picks)
                  _animeCard(context, a),
                const SizedBox(height: 12),
                const Text(APP_CREDIT,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: muted, fontSize: 12)),
              ]),
        ),
      ],
    );
  }

  Widget _heroCard(BuildContext ctx) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: [Color(0xFFFFB347), Color(0xFFFF5E62)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
                color: pink.withOpacity(0.35),
                blurRadius: 24,
                offset: const Offset(0, 10))
          ],
        ),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.25),
                      borderRadius: BorderRadius.circular(999)),
                  child: const Text('FREE 1080p SUB + DUB',
                      style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                          fontSize: 12))),
              const SizedBox(height: 10),
              const Text('Watch anime beautifully.',
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: Colors.black)),
              const Text(
                  'Trailers, simulcasts, classics, hidden downloads with save-to-device.',
                  style: TextStyle(color: Color(0xFF3A2000))),
              const SizedBox(height: 12),
              Row(children: [
                FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white),
                    onPressed: () => Navigator.push(
                        ctx,
                        MaterialPageRoute(
                            builder: (_) =>
                                const SearchTab(full: true))),
                    child: const Text('Find anime')),
                const SizedBox(width: 8),
                OutlinedButton(
                    style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.black,
                        side: const BorderSide(color: Colors.black26)),
                    onPressed: () {},
                    child: const Text('How it works')),
              ]),
            ]),
      );

  Widget _animeCard(BuildContext ctx, Map a) => Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: ListTile(
          contentPadding: const EdgeInsets.all(10),
          leading: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                  colors: [a['g1'] as Color, a['g2'] as Color]),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Center(
                child: Text((a['t'] as String).substring(0, 1),
                    style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: Colors.white))),
          ),
          title: Text(a['t'] as String,
              style: const TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Text(a['e'] as String,
              style: const TextStyle(color: muted, fontSize: 12)),
          trailing: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
                color: amber.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.play_arrow, color: amber),
          ),
          onTap: () => Navigator.push(
              ctx,
              MaterialPageRoute(
                  builder: (_) =>
                      WatchScreen(animeId: a['id'] as int, ep: 1))),
        ),
      );
}

// ── Search ─────────────────────────────────────────────
class SearchTab extends StatefulWidget {
  final bool full;
  const SearchTab({super.key, this.full = false});
  @override
  State<SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<SearchTab> {
  final c = TextEditingController();
  List results = [];
  bool loading = false;
  Future<void> go() async {
    if (c.text.trim().isEmpty) return;
    setState(() => loading = true);
    try {
      final b = await Api.base();
      final r = await http.get(
          Uri.parse('$b/api/heaven/search?q=${Uri.encodeComponent(c.text)}'));
      results = (json.decode(r.body)['results'] as List?) ?? [];
    } catch (_) {
      results = [];
    }
    setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(children: [
      if (!widget.full)
        const GradientHeader(
            title: 'Search', sub: 'AnimeHeaven catalog • SUB + DUB'),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: c,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => go(),
              decoration: const InputDecoration(
                hintText: 'Search anime… e.g. One Piece',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            decoration: BoxDecoration(
                gradient:
                    const LinearGradient(colors: [amber, pink]),
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
              ? const Center(
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                      Icon(Icons.search_rounded,
                          size: 56, color: muted),
                      SizedBox(height: 8),
                      Text('Search anything — results appear here.',
                          style: TextStyle(color: muted)),
                    ]))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: results.length,
                  itemBuilder: (_, i) => Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: ListTile(
                      leading: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                            gradient: const LinearGradient(
                                colors: [purple, pink]),
                            borderRadius: BorderRadius.circular(12)),
                        child: const Icon(Icons.movie,
                            color: Colors.white),
                      ),
                      title: Text(results[i]['title'] ?? '',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700)),
                      subtitle: Text(
                          'AnimeHeaven • ${results[i]['id']}',
                          style: const TextStyle(
                              color: muted, fontSize: 12)),
                      trailing: const Icon(Icons.play_circle_fill,
                          color: amber, size: 30),
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => WatchScreen(
                                  animeId: 113415,
                                  ep: 1,
                                  heavenId: results[i]['id']))),
                    ),
                  ),
                )),
    ]);
    if (widget.full) {
      return Scaffold(
          appBar: AppBar(title: const Text('Search anime')), body: body);
    }
    return body;
  }
}

// ── Library ────────────────────────────────────────────
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
      final pub =
          await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
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
  Widget build(BuildContext context) => Column(children: [
        const GradientHeader(
            title: 'My Library', sub: 'Hidden in-app • export when you want'),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
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
                                fontSize: 18,
                                fontWeight: FontWeight.w800)),
                        Text(
                            'Download from any Watch screen — files stay\ninside the app until you tap Save.',
                            textAlign: TextAlign.center,
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
                                  color: purple.withOpacity(0.15),
                                  borderRadius:
                                      BorderRadius.circular(12)),
                              child: const Icon(Icons.movie,
                                  color: purple)),
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
        ),
      ]);
}

// ── Profile ────────────────────────────────────────────
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
    base.text = p.getString('api_base') ?? API_BASE_DEFAULT;
    name.text = p.getString('username') ?? '';
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => ListView(
        padding: EdgeInsets.zero,
        children: [
          const GradientHeader(
              title: 'You', sub: 'One account • web + Android + Windows'),
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
                        child: Icon(Icons.person,
                            size: 38, color: amber)),
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
                            labelText: 'Website API base URL',
                            prefixIcon: Icon(Icons.link))),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                          style: FilledButton.styleFrom(
                              backgroundColor: amber,
                              foregroundColor: Colors.black),
                          onPressed: () async {
                            final p =
                                await SharedPreferences.getInstance();
                            await p.setString(
                                'api_base', base.text.trim());
                            await p.setString(
                                'username', name.text.trim());
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          'Linked to website API')));
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
              const Text(APP_CREDIT,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: muted, fontSize: 12)),
            ]),
          ),
        ],
      );
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
      final u = await Api.signIn(email.text.trim(), password.text,
          register: register, name: email.text.split('@').first);
      if (!mounted) return;
      setState(() => who = u['email'] as String?);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Signed in as ${u['email']}')));
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
                color: mint.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.verified_user, color: mint)),
        title: Text(who!,
            style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: const Text('Linked — downloads & forums unlocked',
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
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Website account',
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
                            onPressed:
                                busy ? null : () => _go(false),
                            child: Text(busy
                                ? 'Please wait…'
                                : 'Sign in'))),
                    const SizedBox(width: 8),
                    Expanded(
                        child: OutlinedButton(
                            onPressed:
                                busy ? null : () => _go(true),
                            child: const Text('Register'))),
                  ]),
                ])));
  }
}

// ── Watch ──────────────────────────────────────────────
class WatchScreen extends StatefulWidget {
  final int animeId;
  final int ep;
  final String? heavenId;
  const WatchScreen(
      {super.key, required this.animeId, required this.ep, this.heavenId});
  @override
  State<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends State<WatchScreen> {
  VideoPlayerController? vc;
  ChewieController? cc;
  List servers = [];
  Map? active;
  bool loading = true;
  String audio = 'sub';
  @override
  void initState() {
    super.initState();
    _load();
    _resume();
  }

  Future<void> _resume() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('resume_${widget.animeId}', widget.ep);
  }

  Future<void> _load() async {
    try {
      final data = await Api.episodeSources(widget.animeId, widget.ep);
      servers = (data['servers'] as List?) ?? [];
      final subs = servers.where((s) => s['audio'] == audio).toList();
      active = (subs.isNotEmpty ? subs : servers).isNotEmpty
          ? (subs.isNotEmpty ? subs : servers).first
          : null;
      final url = active?['stream_url']?.toString() ?? '';
      if (active?['playback_mode'] != 'iframe' && url.isNotEmpty) {
        vc = VideoPlayerController.networkUrl(Uri.parse(url.startsWith('http')
            ? url
            : '${await Api.base()}$url'));
        await vc!.initialize();
        if (!mounted) return;
        cc = ChewieController(
            videoPlayerController: vc!, autoPlay: true, allowMuting: true);
      }
    } catch (_) {}
    if (mounted) setState(() => loading = false);
  }

  Future<void> _pick(Map s) async {
    setState(() {
      active = s;
      loading = true;
    });
    await vc?.dispose();
    cc?.dispose();
    vc = null;
    cc = null;
    try {
      final url = s['stream_url']?.toString() ?? '';
      if (s['playback_mode'] != 'iframe' && url.isNotEmpty) {
        vc = VideoPlayerController.networkUrl(Uri.parse(url.startsWith('http')
            ? url
            : '${await Api.base()}$url'));
        await vc!.initialize();
        if (!mounted) return;
        cc = ChewieController(
            videoPlayerController: vc!, autoPlay: true, allowMuting: true);
      }
    } catch (_) {}
    if (mounted) setState(() => loading = false);
  }

  Future<void> _downloadActive() async {
    final tok = await Api.token();
    if (tok == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Sign in first (You tab) — then downloads unlock.')));
      }
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Download queued into hidden in-app library')));
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
        appBar: AppBar(
            title: Text('Ep ${widget.ep} • ${audio.toUpperCase()}'),
            backgroundColor: bg),
        body: loading
            ? const Center(
                child: CircularProgressIndicator(color: amber))
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withOpacity(0.5),
                            blurRadius: 20,
                            offset: const Offset(0, 8))
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: cc != null
                          ? Chewie(controller: cc!)
                          : Container(
                              color: card2,
                              padding: const EdgeInsets.all(24),
                              child: const Center(
                                  child: Text(
                                      'Embed-only server.\nPlays in webview on device builds.',
                                      textAlign: TextAlign.center,
                                      style:
                                          TextStyle(color: muted)))),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                        color: card,
                        borderRadius: BorderRadius.circular(999)),
                    child: Row(children: [
                      for (final v in ['sub', 'dub'])
                        Expanded(
                          child: GestureDetector(
                            onTap: () {
                              if (audio == v) return;
                              setState(() {
                                audio = v;
                                loading = true;
                              });
                              _load();
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  vertical: 10),
                              decoration: BoxDecoration(
                                gradient: audio == v
                                    ? const LinearGradient(
                                        colors: [amber, pink])
                                    : null,
                                borderRadius:
                                    BorderRadius.circular(999),
                              ),
                              child: Text(v.toUpperCase(),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      color: audio == v
                                          ? Colors.black
                                          : muted)),
                            ),
                          ),
                        ),
                    ]),
                  ),
                  const SizedBox(height: 8),
                  for (final s
                      in servers.where((x) => x['audio'] == audio))
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      color: active == s ? const Color(0xFF1B2133) : card,
                      child: ListTile(
                        leading: Icon(
                            active == s
                                ? Icons.play_circle_fill
                                : Icons.play_circle_outline,
                            color: amber,
                            size: 30),
                        title: Text(s['name'] ?? 'Server',
                            style: const TextStyle(
                                fontWeight: FontWeight.w700)),
                        subtitle: Text(
                            '${s['quality'] ?? ''} • ${s['playback_mode'] ?? ''}',
                            style: const TextStyle(
                                color: muted, fontSize: 12)),
                        trailing: active == s
                            ? const Icon(Icons.check_circle,
                                color: mint)
                            : null,
                        onTap: () => _pick(s),
                      ),
                    ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: Container(
                      decoration: BoxDecoration(
                          gradient: const LinearGradient(
                              colors: [amber, pink]),
                          borderRadius:
                              BorderRadius.circular(999)),
                      child: FilledButton(
                          style: FilledButton.styleFrom(
                              backgroundColor: Colors.transparent,
                              shadowColor: Colors.transparent,
                              foregroundColor: Colors.black),
                          onPressed: _downloadActive,
                          child: const Text('Download to hidden library',
                              style: TextStyle(
                                  fontWeight: FontWeight.w900))),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(APP_CREDIT,
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(color: muted, fontSize: 12)),
                ],
              ),
      );
}
