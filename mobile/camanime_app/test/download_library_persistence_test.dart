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
    final adoptedFile = manager.completedFile(adopted);
    expect(adoptedFile, isNotNull,
        reason: 'adopting a file must never lose it');
    // Every episode of a series now sits in that series' own folder.
    expect(adoptedFile!.parent.uri.pathSegments.where((p) => p.isNotEmpty).last,
        'Frieren');
    expect(adoptedFile.path, contains('Frieren - Ep 3.mp4'));

    // Persisted, so the next launch (the next app version) sees it too.
    final queue = File('${root.path}/camanime_downloads/queue.json');
    expect(await queue.exists(), isTrue);
    expect(await queue.readAsString(), contains('Frieren - Ep 3.mp4'));
  });

  test('episodes of one series move into one folder together', () async {
    final root = await Directory.systemTemp.createTemp('camanime_folders_');
    addTearDown(() => root.delete(recursive: true));
    PathProviderPlatform.instance = _FakePathProvider(root.path);
    SharedPreferences.setMockInitialValues({});

    final media = Directory('${root.path}/camanime_downloads/media');
    await media.create(recursive: true);
    for (var ep = 1; ep <= 3; ep++) {
      await File('${media.path}/Black Clover - Ep $ep.mp4')
          .writeAsBytes(List<int>.filled(4096, ep));
    }

    final manager = DownloadManager.instance;
    await manager.resetForTests();
    await manager.init();
    addTearDown(manager.resetForTests);

    final series = Directory('${media.path}/Black Clover');
    expect(await series.exists(), isTrue);
    final names = (await series.list().toList())
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .toSet();
    expect(names, {
      'Black Clover - Ep 1.mp4',
      'Black Clover - Ep 2.mp4',
      'Black Clover - Ep 3.mp4',
    });

    // Nothing of this series is left loose beside the folder.
    final loose = (await media.list().toList())
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.startsWith('Black Clover'))
        .toList();
    expect(loose, isEmpty);

    final folder = manager.folders.singleWhere(
        (f) => f.animeTitle == 'Black Clover');
    expect(folder.tasks.map((t) => t.episode).toList(), [1, 2, 3]);
    for (final task in folder.tasks) {
      final file = manager.completedFile(task);
      expect(file, isNotNull);
      expect(file!.parent.uri.pathSegments.where((p) => p.isNotEmpty).last,
          'Black Clover');
    }
  });
}
