import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:camanime_app/core/cam_ui.dart';
import 'package:camanime_app/main.dart';

/// Renders the redesigned detail screen at a small and a large phone size so
/// layout overflows are caught without a device. The network is disabled, so
/// this also exercises the "catalogue unreachable" empty state.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    HttpOverrides.global = _NoNetworkHttpOverrides();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({'tutorial_done': true});
  });

  testWidgets('detail layout fits small and large phones', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Future<void> pumpAt(Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(MaterialApp(
        theme: camTheme(seed: CamColors.accent, background: CamColors.bg),
        home: const DetailScreen(animeId: '1', title: 'Layout check'),
      ));
      await tester.pump();
      // Let the real async fetch fail through both retry attempts.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 900)));
      // The API retry backoff is a fake-async timer; advance it explicitly.
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      // Sections (recommendations, comments) start their own retries on the
      // first frame; advance those too so no timer outlives the test.
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
    }

    await pumpAt(const Size(360, 720));
    expect(find.text('Episodes'), findsOneWidget);
    expect(find.text('Select all'), findsOneWidget);
    expect(find.text('Deselect all'), findsOneWidget);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(411, 891);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

class _NoNetworkHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _FailingHttpClient();
}

class _FailingHttpClient implements HttpClient {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw const SocketException('Network disabled in widget tests');
  }
}
