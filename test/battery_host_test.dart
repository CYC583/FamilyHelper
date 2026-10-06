// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:familyhelper/app/common/firebase_service.dart';
import 'package:familyhelper/app/common/native_bridge.dart';
import 'package:familyhelper/app/host/battery_consent_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _HostBatteryApi extends FirebaseService {
  final consent = StreamController<Map<String, dynamic>>.broadcast(sync: true);

  @override
  String get uid => 'grandma';

  @override
  Stream<Map<String, dynamic>> watch(String path) {
    if (path == 'care/grandma/battery/consent') return consent.stream;
    throw StateError('unexpected path $path');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android 通知關閉時顯示明確警告，不把雲端同意誤作本機分享', (tester) async {
    final api = _HostBatteryApi();
    addTearDown(api.consent.close);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      NativeBridge.channel,
      (call) async {
        if (call.method == 'batterySampleNow') {
          return {
            'batteryPercent': 15,
            'charging': false,
            'shareEnabled': false,
            'revokePending': true,
            'observedAt': DateTime(2026, 10, 2, 12, 0).millisecondsSinceEpoch,
          };
        }
        throw StateError('unexpected native method ${call.method}');
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        NativeBridge.channel,
        null,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: BatteryConsentPage(
          api: api,
          notificationStatus: () async => false,
        ),
      ),
    );
    api.consent.add({'enabled': true, 'status': 'enabled', 'version': 1});
    await tester.pumpAndSettle();

    expect(find.text('目前電量 15%'), findsOneWidget);
    expect(find.textContaining('Android 通知尚未開啟'), findsOneWidget);
    expect(find.text('預設不分享給家人'), findsOneWidget);
    expect(find.text('已在本機開啟分享'), findsNothing);
    expect(find.textContaining('充電狀態'), findsOneWidget);
    expect(find.textContaining('低電量事件'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('通知家人'), 200);
    expect(find.textContaining('通知家人'), findsOneWidget);
  });
}
