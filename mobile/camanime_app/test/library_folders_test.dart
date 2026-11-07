import 'package:flutter_test/flutter_test.dart';

import 'package:camanime_app/core/downloads.dart';
import 'package:camanime_app/core/models.dart';

Map<String, dynamic> bundle() => {
      'servers': [
        {
          'name': 'Main 1080',
          'audio': 'sub',
          'playback_mode': 'mp4',
          'quality': '1080p MP4',
          'stream_url': '/p/1080',
        },
        {
          'name': 'Main 720',
          'audio': 'sub',
          'playback_mode': 'hls',
          'quality': '720p HLS',
          'stream_url': '/p/720',
        },
        {
          'name': 'Dub 720',
          'audio': 'dub',
          'playback_mode': 'mp4',
          'quality': '720p MP4',
          'stream_url': '/p/dub720',
        },
        {
          'name': 'Embed',
          'audio': 'sub',
          'playback_mode': 'iframe',
        },
      ],
    };

String abs(String path) => 'https://cam.example$path';

DownloadTask task({
  required String title,
  required String season,
  required int episode,
  int total = 1000,
  String device = '',
}) =>
    DownloadTask(
      id: '$title-$season-$episode',
      animeId: 1,
      animeTitle: title,
      episode: episode,
      audio: 'sub',
      sourceUrl: 'https://cam.example/file.mp4',
      fileName: '$title - Ep $episode.mp4',
      season: season,
      total: total,
      received: total,
      stage: DownloadStage.completed,
      devicePath: device,
    );

void main() {
  test('sources keep the preferred audio first', () {
    final sources = episodeSourcesFromBundle(
      bundle(),
      animeId: '1',
      episode: 1,
      animeTitle: 'Test',
      image: '',
      preferredAudio: 'sub',
      absolute: abs,
    );
    expect(sources, isNotEmpty);
    expect(sources.first.url, 'https://cam.example/p/1080');
    expect(sources.map((s) => s.url), contains('https://cam.example/p/dub720'));
    // Embed-only servers are never offered as playable sources.
    expect(sources.length, 3);
  });

  test('a quality cap never starts a higher resolution first', () {
    final sources = episodeSourcesFromBundle(
      bundle(),
      animeId: '1',
      episode: 1,
      animeTitle: 'Test',
      image: '',
      preferredAudio: 'sub',
      absolute: abs,
      qualityPreference: '720',
    );
    expect(sources.first.height, 720);
    expect(sources.first.url, 'https://cam.example/p/720');
    // Preferred audio still outranks quality, so the dub 720 lands last.
    expect(sources.map((s) => s.height), [720, 1080, 720]);
    expect(sources.where((s) => s.height <= 720).length, 2);
  });

  test('heights come from provider quality labels', () {
    final sources = episodeSourcesFromBundle(
      bundle(),
      animeId: '1',
      episode: 1,
      animeTitle: 'Test',
      image: '',
      preferredAudio: 'sub',
      absolute: abs,
    );
    expect(sources.first.height, 1080);
    expect(sources.first.qualityLabel, '1080p');
    expect(sources.first.label, contains('1080p'));
  });

  test('folders group episodes by anime and season', () {
    final tasks = [
      task(title: 'Naruto', season: 'Fall 2007', episode: 2, total: 300),
      task(title: 'Naruto', season: 'Fall 2007', episode: 1, total: 200),
      task(title: 'Naruto', season: 'Spring 2007', episode: 1, total: 100),
      task(title: 'Bebop', season: 'Spring 1998', episode: 1, total: 50),
    ];
    final groups = <String, List<DownloadTask>>{};
    for (final t in tasks) {
      groups.putIfAbsent('${t.animeTitle}|${t.season}', () => []).add(t);
    }
    final folders = groups.entries
        .map((e) => DownloadFolder(
              animeTitle: e.value.first.animeTitle,
              season: e.value.first.season,
              tasks: e.value..sort((a, b) => a.episode.compareTo(b.episode)),
            ))
        .toList();
    expect(folders.length, 3);
    final naruto = folders.firstWhere((f) => f.season == 'Fall 2007');
    expect(naruto.tasks.map((t) => t.episode), [1, 2]);
    expect(naruto.bytes, 500);
    expect(naruto.subtitle, 'Fall 2007');
    expect(naruto.allExported, isFalse);
  });

  test('completed label states the episode is finished', () {
    final t = task(title: 'Naruto', season: 'Fall 2007', episode: 3)
      ..completedAt = DateTime(2026, 11, 8, 9, 30).millisecondsSinceEpoch;
    expect(t.completedLabel, startsWith('Completed · 08/11 09:30'));
    expect(t.qualityLabel, 'Auto');
  });

  test('folder reports when every episode is on the device', () {
    final folder = DownloadFolder(
      animeTitle: 'Naruto',
      season: 'Fall 2007',
      tasks: [
        task(title: 'Naruto', season: 'Fall 2007', episode: 1, device: 'a'),
        task(title: 'Naruto', season: 'Fall 2007', episode: 2, device: 'b'),
      ],
    );
    expect(folder.allExported, isTrue);
  });
}
