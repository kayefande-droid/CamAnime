import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The "watchlist" — anime the user wants to come back to, kept on the device
/// only (no account needed) so it survives app updates like the rest of the
/// library data.
class Watchlist {
  Watchlist._();

  static const String _key = 'watchlist_v1';

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

  static Future<bool> contains(String animeId) async =>
      (await _load()).containsKey(animeId);

  /// Adds the anime, or removes it when it is already saved. Returns the new
  /// saved state so the button can flip straight away.
  static Future<bool> toggle({
    required String animeId,
    required String title,
    String image = '',
    int episodes = 0,
  }) async {
    final data = await _load();
    if (data.containsKey(animeId)) {
      data.remove(animeId);
      await _save(data);
      return false;
    }
    data[animeId] = {
      'title': title.substring(0, title.length.clamp(0, 80)),
      'image': image,
      'episodes': episodes,
      'added': DateTime.now().millisecondsSinceEpoch,
    };
    await _save(data);
    return true;
  }

  static Future<void> remove(String animeId) async {
    final data = await _load();
    if (data.remove(animeId) != null) await _save(data);
  }

  /// Newest additions first, in the shape the Library card expects.
  static Future<List<Map<String, dynamic>>> entries() async {
    final data = await _load();
    final rows = <Map<String, dynamic>>[];
    data.forEach((id, raw) {
      if (raw is! Map) return;
      rows.add({
        'id': id,
        'title': (raw['title'] ?? 'Anime').toString(),
        'image': (raw['image'] ?? '').toString(),
        'episodes': int.tryParse('${raw['episodes'] ?? 0}') ?? 0,
        'added': int.tryParse('${raw['added'] ?? 0}') ?? 0,
      });
    });
    rows.sort((a, b) =>
        (b['added'] as int).compareTo(a['added'] as int));
    return rows;
  }
}
