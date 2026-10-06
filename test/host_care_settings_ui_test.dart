// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:familyhelper/app/common/firebase_service.dart';
import 'package:familyhelper/app/common/constants.dart';
import 'package:familyhelper/app/common/ui/fh_theme.dart';
import 'package:familyhelper/app/host/host_care_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _CareApi extends FirebaseService {
  final consent = StreamController<Map<String, dynamic>>.broadcast();

  @override
  String get uid => 'grandma';

  @override
  Stream<Map<String, dynamic>> watch(String path) => consent.stream;
}

void main() {
  testWidgets('照護設定在 360dp、200% 字級可捲動並閱讀分享同意', (tester) async {
    final api = _CareApi();
    addTearDown(api.consent.close);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('familyhelper/native'),
            null,
          );
    });
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('familyhelper/native'), (
          call,
        ) async {
          if (call.method == 'careSnapshot') return <String, Object>{};
          if (call.method == 'loudLevel') return 2;
          return null;
        });

    await tester.pumpWidget(
      MaterialApp(
        theme: buildFhTheme(AppRole.host),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 800),
            textScaler: TextScaler.linear(2),
          ),
          child: HostCareSettingsPage(api: api),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('家人設定的提醒'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('看說明並同意分享'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('看說明並同意分享'));
    await tester.pumpAndSettle();
    expect(find.text('分享給家人'), findsOneWidget);
    expect(find.text('先不要'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
