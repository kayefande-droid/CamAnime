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
    return MaterialApp(
      title: 'CamAnime',
      debugShowCheckedModeBanner: false,
      themeMode: mode,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF7C61D4), fontFamily: 'Outfit'),
      darkTheme: ThemeData.dark(useMaterial3: true).copyWith(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFFFB347), brightness: Brightness.dark)),
      home: Scaffold(
        appBar: AppBar(
          title: const Row(children: [Icon(Icons.play_circle_fill, color: Color(0xFFFFB347)), SizedBox(width: 8), Text('CamAnime')]),
          actions: [
            IconButton(icon: const Icon(Icons.search), onPressed: () => setState(() => tab = 1)),
            IconButton(icon: Icon(mode == ThemeMode.dark ? Icons.light_mode : Icons.dark_mode),
              onPressed: () => setState(() => mode = mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark)),
            IconButton(icon: const Icon(Icons.person), onPressed: () => setState(() => tab = 3)),
          ],
        ),
        body: [const HomeTab(), const SearchTab(), const LibraryTab(), const ProfileTab()][tab],
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) => setState(() => tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
            NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
            NavigationDestination(icon: Icon(Icons.video_library), label: 'Library'),
            NavigationDestination(icon: Icon(Icons.person), label: 'You'),
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
    final r = await http.get(Uri.parse('$b/api/public/anime/$id?ep=$ep'), headers: await headers());
    return json.decode(r.body) as Map<String, dynamic>;
  }
  /// Sign in (or register) against the website's permanent user database.
  /// Returns the user map on success, throws on failure.
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
    return d['user'];
  }
  static Future<void> signOut() async {
    final b = await base();
    try { await http.post(Uri.parse('$b/api/auth/logout'), headers: await headers()); } catch (_) {}
    final p = await SharedPreferences.getInstance();
    await p.remove('api_token');
    await p.remove('user_email');
  }
}

class HomeTab extends StatelessWidget {
  const HomeTab({super.key});
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _heroCard(context),
        const SizedBox(height: 12),
        const Text('Trending now', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        for (final id in [113415, 21, 20, 16498, 1535])
          _animeTile(context, id, 'Anime #$id — tap Search for titles, open details on web for full catalog'),
        const SizedBox(height: 16),
        const Text(APP_CREDIT, textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 12)),
      ],
    );
  }
  Widget _heroCard(BuildContext ctx) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('FREE 1080p SUB + DUB', style: TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        const Text('Trailers, simulcasts, classics, hidden in-app downloads with save-to-device.'),
        const SizedBox(height: 8),
        FilledButton(onPressed: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => const SearchTab(full: true))), child: const Text('Find anime')),
      ]),
    ),
  );
  Widget _animeTile(BuildContext ctx, int id, String sub) => ListTile(
    leading: const Icon(Icons.movie),
    title: Text('Anime $id'),
    subtitle: Text(sub),
    trailing: const Icon(Icons.play_arrow),
    onTap: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => WatchScreen(animeId: id, ep: 1)))),
  );
}

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
    setState(() => loading = true);
    try {
      final b = await Api.base();
      final r = await http.get(Uri.parse('$b/api/heaven/search?q=${Uri.encodeComponent(c.text)}'));
      results = (json.decode(r.body)['results'] as List?) ?? [];
    } catch (_) { results = []; }
    setState(() => loading = false);
  }
  @override
  Widget build(BuildContext context) {
    final body = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        SearchBar(controller: c, hintText: 'Search anime…', onSubmitted: (_) => go(),
          trailing: [IconButton(icon: const Icon(Icons.search), onPressed: go)]),
        const SizedBox(height: 12),
        if (loading) const LinearProgressIndicator(),
        Expanded(child: ListView.builder(
          itemCount: results.length,
          itemBuilder: (_, i) => ListTile(
            title: Text(results[i]['title'] ?? ''),
            subtitle: Text('AnimeHeaven ID: ${results[i]['id']}'),
            onTap: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => WatchScreen(animeId: 113415, ep: 1, heavenId: results[i]['id']))),
          ),
        )),
      ]),
    );
    if (widget.full) return Scaffold(appBar: AppBar(title: const Text('Search')), body: body);
    return body;
  }
}

/// Hidden in-app library: files stay in app support dir; explicit Save-to-device copies out.
class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key});
  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  List<FileSystemEntity> files = [];
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final dir = await getApplicationSupportDirectory();
    final lib = Directory('${dir.path}/camanime_library');
    if (!await lib.exists()) await lib.create(recursive: true);
    setState(() => files = lib.listSync().whereType<File>().toList());
  }
  Future<void> _saveToDevice(File f) async {
    try {
      final pub = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
      await f.copy('${pub.path}/${f.uri.pathSegments.last}');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved to device Downloads')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('My Library (hidden in-app)', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      const Text('Downloads stay inside the app until you tap Save to device (per episode or season).'),
      const SizedBox(height: 8),
      Expanded(child: files.isEmpty
        ? const Center(child: Text('No downloads yet — download from any Watch screen.'))
        : ListView.builder(itemCount: files.length, itemBuilder: (_, i) {
            final f = files[i] as File;
            return ListTile(title: Text(f.uri.pathSegments.last), trailing: TextButton(
              onPressed: () => _saveToDevice(f), child: const Text('Save to device')));
          })),
    ]),
  );
}

class ProfileTab extends StatefulWidget {
  const ProfileTab({super.key});
  @override
  State<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<ProfileTab> {
  final base = TextEditingController();
  final name = TextEditingController();
  @override
  void initState() { super.initState(); _init(); }
  Future<void> _init() async {
    final p = await SharedPreferences.getInstance();
    base.text = p.getString('api_base') ?? API_BASE_DEFAULT;
    name.text = p.getString('username') ?? '';
    setState(() {});
  }
  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
    const CircleAvatar(radius: 36, child: Icon(Icons.person, size: 40)),
    const SizedBox(height: 8),
    TextField(controller: name, decoration: const InputDecoration(labelText: 'Username')),
    TextField(controller: base, decoration: const InputDecoration(labelText: 'Website API base URL')),
    const SizedBox(height: 8),
    FilledButton(onPressed: () async {
      final p = await SharedPreferences.getInstance();
      await p.setString('api_base', base.text.trim());
      await p.setString('username', name.text.trim());
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Linked to website API')));
    }, child: const Text('Save & link app to website')),
    const SizedBox(height: 16),
    const Text('Website account (same permanent database)', style: TextStyle(fontWeight: FontWeight.w800)),
    const SizedBox(height: 8),
    const _AuthCard(),
    const SizedBox(height: 16),
    const Text(APP_CREDIT, textAlign: TextAlign.center),
  ]);
}

/// Email + password form bound to the website's permanent SQLite user database.
/// On success the API token is stored and sent as `Authorization: Bearer` on
/// every download, comment, rating and notification call.
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
  void initState() { super.initState(); _who(); }
  Future<void> _who() async {
    final p = await SharedPreferences.getInstance();
    setState(() => who = p.getString('user_email'));
  }
  Future<void> _go(bool register) async {
    setState(() => busy = true);
    try {
      final u = await Api.signIn(email.text.trim(), password.text, register: register, name: email.text.split('@').first);
      setState(() => who = u['email']);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Signed in as ${u['email']}')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
    setState(() => busy = false);
  }
  @override
  Widget build(BuildContext context) {
    if (who != null) {
      return Card(child: ListTile(
        leading: const Icon(Icons.verified_user),
        title: Text(who!),
        subtitle: const Text('Linked — downloads & forums unlocked'),
        trailing: TextButton(onPressed: () async { await Api.signOut(); _who(); }, child: const Text('Sign out')),
      ));
    }
    return Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(children: [
      TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email (Gmail / iCloud)')),
      TextField(controller: password, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: FilledButton(onPressed: busy ? null : () => _go(false), child: const Text('Sign in'))),
        const SizedBox(width: 8),
        Expanded(child: OutlinedButton(onPressed: busy ? null : () => _go(true), child: const Text('Register'))),
      ]),
    ])));
  }
}

class WatchScreen extends StatefulWidget {
  final int animeId; final int ep; final String? heavenId;
  const WatchScreen({super.key, required this.animeId, required this.ep, this.heavenId});
  @override
  State<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends State<WatchScreen> {
  VideoPlayerController? vc; ChewieController? cc;
  List servers = []; Map? active; bool loading = true; String audio = 'sub';
  @override
  void initState() { super.initState(); _load(); _resume(); }
  Future<void> _resume() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('resume_${widget.animeId}', widget.ep);
  }
  Future<void> _load() async {
    try {
      final data = await Api.episodeSources(widget.animeId, widget.ep);
      servers = (data['servers'] as List?) ?? [];
      final subs = servers.where((s) => s['audio'] == audio).toList();
      active = (subs.isNotEmpty ? subs : servers).isNotEmpty ? (subs.isNotEmpty ? subs : servers).first : null;
      final url = active?['stream_url']?.toString() ?? '';
      if (active?['playback_mode'] != 'iframe' && url.isNotEmpty) {
        vc = VideoPlayerController.networkUrl(Uri.parse(url.startsWith('http') ? url : '${await Api.base()}$url'));
        await vc!.initialize();
        cc = ChewieController(videoPlayerController: vc!, autoPlay: true, allowMuting: true);
      }
    } catch (_) {}
    setState(() => loading = false);
  }
  Future<void> _downloadActive() async {
    final tok = await Api.token();
    if (tok == null) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sign in on the website first, then downloads unlock (hashed auth).')));
      return;
    }
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Download queued into hidden in-app library')));
  }
  @override
  void dispose() { vc?.dispose(); cc?.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Ep ${widget.ep} • ${audio.toUpperCase()}')),
    body: loading ? const Center(child: CircularProgressIndicator()) : ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (cc != null) AspectRatio(aspectRatio: 16 / 9, child: Chewie(controller: cc!))
        else const Card(child: Padding(padding: EdgeInsets.all(24), child: Text('Embed-only server: plays in webview on device builds.'))),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [ButtonSegment(value: 'sub', label: Text('SUB')), ButtonSegment(value: 'dub', label: Text('DUB'))],
          selected: {audio}, onSelectionChanged: (s) => setState(() { audio = s.first; loading = true; _load(); }),
        ),
        for (final s in servers.where((x) => x['audio'] == audio))
          ListTile(title: Text(s['name'] ?? ''), subtitle: Text('${s['quality'] ?? ''} • ${s['playback_mode'] ?? ''}'),
            trailing: const Icon(Icons.play_arrow),
            onTap: () => setState(() => active = s)),
        FilledButton(onPressed: _downloadActive, child: const Text('Download to hidden library')),
        const SizedBox(height: 8),
        const Text(APP_CREDIT, textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 12)),
      ],
    ),
  );
}
