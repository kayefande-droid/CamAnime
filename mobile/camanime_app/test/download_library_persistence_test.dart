// An app update must never look like it wiped the user's offline library.
// Files live in app storage (untouched by an APK update); this checks that even
// when the queue index is missing, finished episodes are adopted back into the
// Library and persisted for the next launch.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:camanime_app/core/downloads.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('finished episode files are recovered without a queue index', () async {
    final root = await Directory.systemTemp.createTemp('camanime_update_');
    addTearDown(() => root.delete(recursive: true));
    PathProviderPlatform.instance = _FakePathProvider(root.path);
    SharedPreferences.setMockInitialValues({});

    final media = Directory('${root.path}/camanime_downloads/media');
    await media.create(recursive: true);
    final saved = File('${media.path}/Frieren - Ep 3.mp4');
    await saved.writeAsBytes(List<int>.filled(4096, 7));

    final manager = DownloadManager.instance;
    await manager.init();

    expect(manager.ready, isTrue);
    final completed = manager.completed;
    expect(completed, isNotEmpty);
    final adopted = completed.firstWhere(
        (t) => t.animeTitle.contains('Frieren'),
        orElse: () => throw StateError('saved episode was not adopted'));
    expect(adopted.localName, isNotNull);
    expect(await File(adopted.localName!).exists(), isTrue,
        reason: 'adopting a file must never move or delete it');

    // Persisted, so the next launch (the next app version) sees it too.
    final queue = File('${root.path}/camanime_downloads/queue.json');
    expect(await queue.exists(), isTrue);
    expect(await queue.readAsString(), contains('Frieren - Ep 3.mp4'));
  });
}
