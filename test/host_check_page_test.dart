// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:familyhelper/app/common/firebase_service.dart';
import 'package:familyhelper/app/common/native_bridge.dart';
import 'package:familyhelper/app/host/host_check_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Api extends FirebaseService {
  @override
  String get uid => 'grandma';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<List<String>> pump(
    WidgetTester tester, {
    required bool notifications,
    required List<String> soundProblems,
  }) async {
    SharedPreferences.setMockInitialValues({'healthEnabled': false});
    final opened = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      NativeBridge.channel,
      (call) async {
        switch (call.method) {
          case 'careSnapshot':
            return {
              'notificationsAllowed': notifications,
              'enabled': true,
              'disclosure': 2,
              'sound': {'problems': soundProblems},
              'companionItems': {'mood': true, 'responses': false},
            };
          case 'placeSnapshot':
            return {'enabled': false};
          case 'batterySnapshot':
            return {'shareEnabled': true};
          case 'appInfo':
            return {'version': '1.5.0', 'batteryUnrestricted': true};
          case 'accessibilityEnabled':
            return true;
          default:
            opened.add(call.method);
            return null;
        }
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        NativeBridge.channel,
        null,
      ),
    );
    await tester.pumpWidget(MaterialApp(home: HostCheckPage(api: _Api())));
    await tester.pumpAndSettle();
    return opened;
  }

  testWidgets('全部正常：顯示都設定好，並列出正在分享的項目', (tester) async {
    await pump(tester, notifications: true, soundProblems: []);
    expect(find.text('看起來都設定好了'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('正在分享電量給家人'), 200);
    await tester.scrollUntilVisible(find.text('正在分享：今天的心情'), 200);
    await tester.scrollUntilVisible(find.text('App 版本：1.5.0'), 200);
  });

  testWidgets('通知關閉、靜音：列出要調整的項目並可直接去設定', (tester) async {
    final opened = await pump(
      tester,
      notifications: false,
      soundProblems: ['鈴聲是靜音，來電和通知不會響'],
    );
    expect(find.text('有 2 項要調整'), findsOneWidget);
    expect(find.text('鈴聲是靜音，來電和通知不會響'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, '去開啟').first);
    await tester.pumpAndSettle();
    expect(opened, contains('openNotificationSettings'));
  });
}
