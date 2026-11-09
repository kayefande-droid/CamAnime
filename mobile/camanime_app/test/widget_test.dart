import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:camanime_app/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    HttpOverrides.global = _NoNetworkHttpOverrides();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({'tutorial_done': true});
  });

  testWidgets(
      'CamAnime home renders primary navigation and catalogue loading state',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const CamAnimeApp());
    await tester.pump();

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('CamAnime'), findsOneWidget);
    expect(find.text('Episode 1'), findsOneWidget);
    expect(find.text('My Library'), findsOneWidget);
    expect(find.text('Downloading'), findsNothing);
    expect(find.text('Nothing saved yet'), findsNothing);
  });

  testWidgets('library shows empty state when nothing is downloaded',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const CamAnimeApp());
    await tester.pump();
    await tester.tap(find.text('Library'));
    await tester.pump();
    // Let the real async work finish (file scan plus the API retry backoff);
    // fake-async pumps alone cannot drive IO.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1200)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('My Library'), findsWidgets);
    expect(find.text('Nothing saved yet'), findsOneWidget);
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
