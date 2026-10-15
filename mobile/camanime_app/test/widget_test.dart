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

    expect(find.byKey(const ValueKey('camanime-brand-logo')), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Explore'), findsOneWidget);
    expect(find.text('Search'), findsOneWidget);
    expect(find.text('Downloads'), findsOneWidget);
    expect(find.text('My Library'), findsOneWidget);
    expect(find.text('Profile'), findsOneWidget);
  });

  testWidgets('downloads explains authorized-source limitation',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const CamAnimeApp());
    await tester.pump();
    await tester.tap(find.text('Downloads'));
    await tester.pumpAndSettle();

    expect(find.text('No authorized download sources are configured.'),
        findsOneWidget);
  });
}

class _NoNetworkHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _UnavailableHttpClient();
}

class _UnavailableHttpClient implements HttpClient {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #getUrl) {
      throw const SocketException('Network disabled in widget tests');
    }
    return super.noSuchMethod(invocation);
  }
}
