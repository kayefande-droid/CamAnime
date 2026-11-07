// Verifies the core promise of the download engine: an interrupted transfer
// resumes from the exact byte offset with a Range request and ends with a
// complete, playable file — no restart from zero.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camanime_app/core/downloads.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getDownloadsPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

/// Serves a fixed payload with HTTP Range semantics, like the media server.
class _RangeClient extends http.BaseClient {
  _RangeClient(this.payload, this.onRange);
  final List<int> payload;
  final void Function(String range) onRange;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final range = request.headers['Range'] ?? request.headers['range'] ?? '';
    onRange(range);
    final match = RegExp(r'bytes=(\d+)-').firstMatch(range);
    final start = int.tryParse(match?.group(1) ?? '') ?? 0;
    final slice = payload.sublist(start.clamp(0, payload.length));
    return http.StreamedResponse(
      Stream<List<int>>.value(slice),
      start > 0 ? 206 : 200,
      contentLength: slice.length,
      headers: {
        'content-type': 'video/mp4',
        'content-range': 'bytes $start-${payload.length - 1}/${payload.length}',
      },
      request: request,
    );
  }
}

/// Streams a stitched HLS episode: no Content-Length, only a byte estimate.
class _EstimateClient extends http.BaseClient {
  _EstimateClient(this.payload, this.declared, {this.exact = false});
  final List<int> payload;
  final int declared;
  final bool exact;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    Stream<List<int>> body() async* {
      const chunk = 20000;
      for (var i = 0; i < payload.length; i += chunk) {
        yield payload.sublist(i, (i + chunk).clamp(0, payload.length));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    return http.StreamedResponse(
      body(),
      200,
      headers: {
        'content-type': 'video/mp2t',
        'x-total-bytes': '$declared',
        'x-total-exact': exact ? '1' : '0',
      },
      request: request,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  var lastRange = '';
  const total = 240000;
  final payload = List<int>.generate(total, (i) => i % 251);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('camanime_dl_');
    PathProviderPlatform.instance = _FakePathProvider(temp.path);
    lastRange = '';
  });

  tearDown(() async {
    final manager = DownloadManager.instance;
    manager.clientFactory = null;
    manager.allowInsecureForTests = false;
    await manager.resetForTests();
    if (await temp.exists()) {
      try {
        await temp.delete(recursive: true);
      } catch (_) {}
    }
  });

  test('a partial transfer resumes with Range and completes', () async {
    final manager = DownloadManager.instance;
    manager.allowInsecureForTests = true;
    manager.clientFactory =
        () => _RangeClient(payload, (range) => lastRange = range);
    await manager.resetForTests();
    await manager.init();

    const animeId = 7;
    const episode = 3;
    const audio = 'sub';
    final url = 'http://127.0.0.1/episode.mp4';
    final id = sha256
        .convert(utf8.encode('$animeId|$episode|$audio|$url'))
        .toString()
        .substring(0, 20);

    // Simulate a transfer that was killed after 90,000 bytes.
    final media = Directory('${temp.path}/camanime_downloads/media');
    await media.create(recursive: true);
    final part = File('${media.path}/$id.part');
    await part.writeAsBytes(payload.sublist(0, 90000), flush: true);

    final task = await manager.enqueue(
      animeTitle: 'Test Show',
      animeId: animeId,
      episode: episode,
      audio: audio,
      url: url,
    );

    for (var i = 0; i < 120; i++) {
      if (task.stage == DownloadStage.completed ||
          task.stage == DownloadStage.failed) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    expect(task.stage, DownloadStage.completed, reason: 'error: ${task.error}');
    expect(lastRange, 'bytes=90000-');
    expect(task.total, total);
    expect(manager.readyCount, 1);

    final saved = manager.completedFile(task);
    expect(saved, isNotNull);
    expect(await saved!.length(), total);
    expect(await File('${media.path}/$id.part').exists(), isFalse);

    // The queue survives a restart: the completed task reloads from disk with
    // its file still playable.
    await manager.resetForTests();
    await manager.init();
    final reloaded = manager.taskFor(animeId, episode);
    expect(reloaded, isNotNull);
    expect(reloaded!.stage, DownloadStage.completed);
    expect(await manager.playableFile(reloaded)!.length(), total);
  });

  test('a server without Range support restarts cleanly', () async {
    final manager = DownloadManager.instance;
    manager.allowInsecureForTests = true;
    manager.clientFactory = () => _RangeClient(payload, (range) async {});
    await manager.resetForTests();
    await manager.init();

    const animeId = 11;
    const url = 'http://127.0.0.1/norange.mp4';
    final task = await manager.enqueue(
      animeTitle: 'No Range Show',
      animeId: animeId,
      episode: 2,
      audio: 'sub',
      url: url,
    );
    for (var i = 0; i < 120; i++) {
      if (task.stage == DownloadStage.completed) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(task.stage, DownloadStage.completed, reason: task.error);
    expect(await manager.playableFile(task)!.length(), total);
  });

  test('a stitched stream with an estimated total still completes', () async {
    final manager = DownloadManager.instance;
    manager.allowInsecureForTests = true;
    // The server's guess is deliberately too high: completion must come from
    // the end of the stream, not from the estimate.
    manager.clientFactory = () => _EstimateClient(payload, total * 3 ~/ 2);
    await manager.resetForTests();
    await manager.init();

    final task = await manager.enqueue(
      animeTitle: 'Stitched Show',
      animeId: 21,
      episode: 1,
      audio: 'sub',
      url: 'http://127.0.0.1/api/download/hls?url=x.m3u8&height=1080',
    );
    // Stitched HLS is MPEG-TS: naming it .mp4 breaks the player's extractor.
    expect(task.fileName.endsWith('.ts'), isTrue);

    for (var i = 0; i < 80 && task.received == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(task.total, greaterThan(0), reason: 'the bar needs a total');
    expect(task.estimated, isTrue);
    expect(task.progress, isNotNull);

    for (var i = 0; i < 200; i++) {
      if (task.stage == DownloadStage.completed ||
          task.stage == DownloadStage.failed) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(task.stage, DownloadStage.completed, reason: task.error);
    expect(task.estimated, isFalse);
    expect(task.total, total);
    expect(await manager.playableFile(task)!.length(), total);
  });

  test('an exact total header drives a determinate, authoritative bar', () async {
    final manager = DownloadManager.instance;
    manager.allowInsecureForTests = true;
    manager.clientFactory = () => _EstimateClient(payload, total, exact: true);
    await manager.resetForTests();
    await manager.init();

    final task = await manager.enqueue(
      animeTitle: 'Exact Show',
      animeId: 22,
      episode: 1,
      audio: 'sub',
      url: 'http://127.0.0.1/api/download/hls?url=y.m3u8',
    );

    for (var i = 0; i < 200; i++) {
      if (task.stage == DownloadStage.completed ||
          task.stage == DownloadStage.failed) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(task.stage, DownloadStage.completed, reason: task.error);
    // A summed total is authoritative: no estimate flag, exact byte count.
    expect(task.estimated, isFalse);
    expect(task.total, total);
    expect(await manager.playableFile(task)!.length(), total);
  });

  test('queue state round-trips byte offsets and stages', () {
    final task = DownloadTask(
      id: 'abc123',
      animeId: 42,
      animeTitle: 'Show',
      episode: 5,
      audio: 'dub',
      sourceUrl: 'https://example.test/ep5.mp4',
      fileName: 'Show - Ep 5.mp4',
      received: 1500000,
      total: 3000000,
      stage: DownloadStage.paused,
      error: 'No internet',
      updatedAt: 1234,
    );
    final restored = DownloadTask.fromJson(task.toJson());
    expect(restored.id, 'abc123');
    expect(restored.episode, 5);
    expect(restored.audio, 'dub');
    expect(restored.received, 1500000);
    expect(restored.total, 3000000);
    expect(restored.stage, DownloadStage.paused);
    expect(restored.progress, closeTo(0.5, 0.001));
    expect(restored.isPlayablePartially, isTrue);
    final tiny = DownloadTask.fromJson(DownloadTask(
      id: 'x',
      animeId: 1,
      animeTitle: 'A',
      episode: 1,
      audio: 'sub',
      sourceUrl: 'https://example.test/a.mp4',
      fileName: 'a.mp4',
      received: 2048,
      total: 900000,
    ).toJson());
    expect(tiny.isPlayablePartially, isFalse);
  });
}
