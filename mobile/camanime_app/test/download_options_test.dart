import 'package:flutter_test/flutter_test.dart';

import 'package:camanime_app/core/models.dart';

void main() {
  Map<String, dynamic> bundle() => {
        'downloads': [
          {
            'label': 'Episode 1 (SUB · 1080p)',
            'quality': '1080p',
            'audio': 'SUB',
            'url': '/api/download/video?url=https%3A%2F%2Fa.example%2F1080.mp4',
            'direct': true,
          },
          {
            'label': 'Episode 1 (SUB · 720p)',
            'quality': '720p',
            'audio': 'SUB',
            'url': '/api/download/video?url=https%3A%2F%2Fa.example%2F720.mp4',
            'direct': true,
          },
          {
            // HLS playlists cannot be saved by the offline engine.
            'label': 'Episode 1 (SUB · HLS)',
            'quality': 'HLS playlist',
            'audio': 'SUB',
            'url':
                '/api/download/video?url=https%3A%2F%2Fa.example%2Fmaster.m3u8',
            'direct': true,
          },
          {
            // Provider landing pages are not video files.
            'label': 'Episode 1 (SUB · 360p)',
            'quality': '360p',
            'audio': 'SUB',
            'url': 'https://pahe.example/OtrUN',
            'direct': false,
          },
        ],
        'servers': [
          {
            'name': 'AnimeHeaven Primary',
            'audio': 'sub',
            'playback_mode': 'mp4',
            'quality': '1080p MP4',
            'download_url':
                '/api/download/video?url=https%3A%2F%2Fa.example%2Fheaven.mp4',
          },
          {
            'name': 'Embed',
            'audio': 'sub',
            'playback_mode': 'iframe',
          },
          {
            // HLS now exposes one stitched file instead of a playlist.
            'name': 'CamStream HD-1 (SUB)',
            'audio': 'sub',
            'playback_mode': 'hls',
            'quality': '1080p HLS',
            'download_url':
                '/api/download/hls?url=https%3A%2F%2Fa.example%2Fmaster.m3u8&title=Ep+1&height=1080',
          },
        ],
      };

  String absolute(String url) =>
      url.startsWith('http') ? url : 'https://cam.example$url';

  test('lists only direct video files, preferred audio first', () {
    final options =
        downloadOptions(bundle(), preferredAudio: 'sub', absolute: absolute);
    final urls = options.map((o) => o.url).toList();
    expect(urls, isNotEmpty);
    expect(urls.every((u) => !isPlaylistUrl(u)), isTrue);
    expect(urls.every((u) => !u.contains('pahe.example')), isTrue);
    expect(
        urls,
        contains(
            'https://cam.example/api/download/video?url=https%3A%2F%2Fa.example%2Fheaven.mp4'));
    expect(options.every((o) => o.audio == 'sub'), isTrue);
  });

  test('stitched HLS downloads are offered, playlists stay excluded', () {
    final options =
        downloadOptions(bundle(), preferredAudio: 'sub', absolute: absolute);
    final urls = options.map((o) => o.url).toList();
    expect(
        urls,
        containsAll(<String>[
          'https://cam.example/api/download/hls?url=https%3A%2F%2Fa.example%2Fmaster.m3u8&title=Ep+1&height=1080',
        ]));
    // A bare playlist, even wrapped in the download proxy, is never offered.
    expect(
        urls.any((u) =>
            u.contains('/api/download/video') && u.contains('master.m3u8')),
        isFalse);
    expect(isPlaylistUrl('/api/download/hls?url=https%3A%2F%2Fa%2Fx.m3u8'),
        isFalse);
  });

  test('smallest and best preferences pick real heights', () {
    final options =
        downloadOptions(bundle(), preferredAudio: 'sub', absolute: (u) => u);
    expect(pickDownloadOption(options, 'smallest')?.height, 720);
    expect(pickDownloadOption(options, 'best')?.height, 1080);
  });

  test('resolution caps pick the highest file at or below the target', () {
    final options =
        downloadOptions(bundle(), preferredAudio: 'sub', absolute: (u) => u);
    // A 720p cap must never hand back the 1080p file.
    expect(pickDownloadOption(options, '720')?.height, 720);
    expect(pickDownloadOption(options, '1080')?.height, 1080);
    // Nothing at or below 360p exists, so the smallest real file is used.
    expect(pickDownloadOption(options, '360')?.height, 720);
    expect(downloadQualityLabel('720'), 'Up to 720p (published files)');
  });

  test('downloadHeight reads provider labels', () {
    expect(downloadHeight('1080p / 720p MP4'), 1080);
    expect(downloadHeight('720p MP4'), 720);
    expect(downloadHeight('HLS playlist'), 0);
  });
}
