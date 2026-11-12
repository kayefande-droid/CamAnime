import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// Sends the two events that feed the public counters.
///
/// The server stores them in its events table, which is the same table the
/// website writes to and the same one the anime page reads back, so the number
/// under a title is shared by every user and survives a redeploy. A failed
/// report is dropped: playback and downloads must never depend on analytics.
class ActivityCounters {
  static Future<void> _post(Map<String, dynamic> body) async {
    try {
      await http
          .post(
            Uri.parse('${apiHost.replaceFirst(RegExp(r'/+$'), '')}/api/track'),
            headers: const {'content-type': 'application/json'},
            body: json.encode(body),
          )
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // Offline or blocked: the title simply keeps its existing count.
    }
  }

  /// One real playback start, counted once per episode.
  static Future<void> play(String animeId, String episode) => _post({
        'kind': 'play',
        'anime_id': animeId,
        'ep': episode,
      });

  /// One finished download of an episode.
  static Future<void> download(String animeId, String episode) => _post({
        'kind': 'download',
        'anime_id': animeId,
        'ep': episode,
      });
}
