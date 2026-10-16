// Focused tests for the download guards, the persistent media library and the
// playback-source helpers. These run without a device or network.

import 'dart:io';

import 'package:camanime_app/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getDownloadsPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('camanime_test_');
    PathProviderPlatform.instance = _FakePathProvider(temp.path);
  });

  tearDown(() async {
    if (await temp.exists()) {
      try {
        await temp.delete(recursive: true);
      } catch (_) {}
    }
  });

  group('download guards', () {
    test('only real video content types are downloadable', () {
      for (final ok in const [
        'video/mp4',
        'video/mp4; charset=utf-8',
        'video/webm',
        'video/x-matroska',
        'application/octet-stream',
        'application/mp4',
      ]) {
        expect(Api.isPlayableVideoType(ok), isTrue, reason: ok);
      }
      for (final bad in const [
        'text/html',
        'text/html; charset=utf-8',
        'application/json',
        'application/vnd.apple.mpegurl',
        '',
      ]) {
        expect(Api.isPlayableVideoType(bad), isFalse, reason: bad);
      }
    });

    test('filenames cannot escape the library directory', () {
      expect(Api.safeMediaFilename('../../etc/passwd'), 'passwd');
      expect(Api.safeMediaFilename('..\\..\\windows\\system32'),
          'system32');
      expect(Api.safeMediaFilename('/tmp/Show - Ep 1.mp4'),
          'Show - Ep 1.mp4');
      expect(Api.safeMediaFilename('a/b/c.mp4'), 'c.mp4');
      expect(Api.safeMediaFilename('..'), 'CamAnime_Episode.mp4');
      expect(Api.safeMediaFilename(''), 'CamAnime_Episode.mp4');
      // Shell/URL metacharacters are stripped.
      expect(Api.safeMediaFilename('ep;rm -rf *.mp4').contains(';'), isFalse);
    });

    test('relative episode URLs resolve against the website', () {
      expect(Api.abs('/api/download/video?url=x'),
          '${Api.base()}/api/download/video?url=x');
      expect(Api.abs('https://cdn.example/ep.mp4'),
          'https://cdn.example/ep.mp4');
    });

    test('insecure download sources are refused before any transfer', () async {
      expect(
        () => Api.downloadEpisodeFile('http://insecure.example/ep.mp4', 'e.mp4'),
        throwsA(isA<HttpException>()),
      );
      expect(
        () => Api.downloadEpisodeFile('http://insecure.example/ep.mp4', 'e.mp4')
            .then((v) => v.downloadedBytes),
        throwsA(isA<HttpException>()),
      );
    });
  });

  group('media library', () {
    Future<File> writeEpisode(String name) async {
      final library = await MediaLibrary.directory();
      final file = File('${library.path}/$name');
      await file.writeAsBytes(List<int>.filled(64, 7), flush: true);
      return file;
    }

    test('a completed download is recorded and survives a reload', () async {
      final file = await writeEpisode('hash1-Show - Ep 1.mp4');
      await MediaLibrary.record(
        file: file,
        title: 'Show - Ep 1',
        animeId: 42,
        episode: 1,
        audio: 'sub',
        sizeBytes: 64,
      );

      final items = await MediaLibrary.list();
      expect(items, hasLength(1));
      expect(items.first.title, 'Show - Ep 1');
      expect(items.first.animeId, 42);
      expect(items.first.episode, 1);
      expect(items.first.audio, 'sub');
      expect(items.first.sizeBytes, 64);
      expect(await items.first.file.exists(), isTrue);
    });

    test('re-recording the same episode does not duplicate it', () async {
      final file = await writeEpisode('hash1-Show - Ep 1.mp4');
      for (var i = 0; i < 3; i++) {
        await MediaLibrary.record(
          file: file,
          title: 'Show - Ep 1',
          animeId: 42,
          episode: 1,
          audio: 'sub',
          sizeBytes: 64,
        );
      }
      expect(await MediaLibrary.list(), hasLength(1));
    });

    test('partial and non-video files never appear as library entries',
        () async {
      await writeEpisode('hash1-Show - Ep 1.mp4');
      final library = await MediaLibrary.directory();
      // An interrupted transfer, an index file and a stray text file.
      await File('${library.path}/hash2-Ep 2.mp4.part')
          .writeAsBytes(List<int>.filled(64, 7));
      await File('${library.path}/library.json.tmp').writeAsString('[]');
      await File('${library.path}/notes.mp4').writeAsString('too small');
      await File('${library.path}/poster.jpg')
          .writeAsBytes(List<int>.filled(64, 7));

      final items = await MediaLibrary.list();
      expect(items, hasLength(1));
      expect(items.first.title, 'hash1-Show - Ep 1.mp4');
    });

    test('deleting removes both the file and its record', () async {
      final file = await writeEpisode('hash1-Show - Ep 1.mp4');
      await MediaLibrary.record(
        file: file,
        title: 'Show - Ep 1',
        animeId: 42,
        episode: 1,
        audio: 'sub',
        sizeBytes: 64,
      );

      final item = (await MediaLibrary.list()).single;
      await MediaLibrary.delete(item);

      expect(await file.exists(), isFalse);
      expect(await MediaLibrary.list(), isEmpty);

      // The index is still valid JSON after the delete.
      final manifest = await MediaLibrary.directory().then(
          (d) => File('${d.path}/library.json'));
      expect(manifest.existsSync(), isTrue);
      expect(manifest.readAsStringSync().trim(), '[]');
    });

    test('a corrupt index is recovered from the files on disk', () async {
      final file = await writeEpisode('hash1-Show - Ep 1.mp4');
      final library = await MediaLibrary.directory();
      await File('${library.path}/library.json').writeAsString('{not json');

      // The unreadable index must not crash the library; the file is still
      // listed with safe fallbacks.
      final items = await MediaLibrary.list();
      expect(items, hasLength(1));
      expect(items.first.file.uri.pathSegments.last,
          file.uri.pathSegments.last);
      expect(items.first.audio, 'sub');
    });
  });
}
