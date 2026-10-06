// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';
import 'package:familyhelper/app/client/battery_guardian_panel.dart';
import 'package:familyhelper/app/common/firebase_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _BatteryApi extends FirebaseService {
  final consent = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final latest = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final preferences = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );
  final calls = <String>[];
  final watched = <String>[];
  bool failAck = false;

  @override
  String get uid => 'member-1';
  @override
  Stream<Map<String, dynamic>> watch(String path) {
    watched.add(path);
    if (path.endsWith('/consent')) return consent.stream;
    if (path.endsWith('/latest')) return latest.stream;
    if (path.contains('/preferences/')) return preferences.stream;
    throw StateError('unexpected path $path');
  }

  @override
  Stream<Map<String, dynamic>> batteryEvents(String hostId) => events.stream;
  @override
  Future<Map<String, dynamic>> call(
    String name, [
    Map<String, dynamic> data = const {},
  ]) async {
    calls.add(name);
    if (failAck && name == 'ackBatteryEvent') throw StateError('暫時無法確認');
    return {'ok': true};
  }

  Future<void> close() async {
    await consent.close();
    await latest.close();
    await events.close();
    await preferences.close();
  }
}

void main() {
  testWidgets('舊同意不能訂閱詳細電量，回退舊版本會立刻隱藏快取', (tester) async {
    final api = _BatteryApi();
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [BatteryGuardianPanel(api: api, hostId: 'grandma')],
          ),
        ),
      ),
    );
    api.consent.add({'enabled': true, 'status': 'enabled', 'version': 1});
    await tester.pump();
    expect(find.textContaining('重新確認新版電量分享說明'), findsOneWidget);
    expect(api.watched.where((path) => path.endsWith('/latest')), isEmpty);

    api.consent.add({
      'enabled': true,
      'status': 'enabled',
      'version': 2,
      'disclosureVersion': 2,
    });
    await tester.pump();
    api.latest.add({
      'batteryPercent': 15,
      'charging': false,
      'observedAt': 1000,
      'receivedAt': 1000,
    });
    await tester.pump();
    expect(find.text('15%'), findsOneWidget);

    api.consent.add({
      'enabled': true,
      'status': 'enabled',
      'version': 3,
      'disclosureVersion': 1,
    });
    await tester.pump();
    expect(find.text('15%'), findsNothing);
    expect(find.textContaining('重新確認新版電量分享說明'), findsOneWidget);
  });

  testWidgets('未同意不訂閱私人電量，也不顯示假正常', (tester) async {
    final api = _BatteryApi();
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BatteryGuardianPanel(api: api, hostId: 'grandma'),
        ),
      ),
    );
    api.consent.add({'enabled': false, 'status': 'paused', 'version': 2});
    await tester.pump();
    expect(find.textContaining('尚未同意分享電量'), findsOneWidget);
    expect(find.text('正常'), findsNothing);
  });

  testWidgets('資料過期、個別確認失敗與本人通知偏好如實呈現', (tester) async {
    final api = _BatteryApi();
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [BatteryGuardianPanel(api: api, hostId: 'grandma')],
          ),
        ),
      ),
    );
    api.consent.add({
      'enabled': true,
      'status': 'enabled',
      'version': 1,
      'disclosureVersion': 2,
    });
    await tester.pumpAndSettle();
    await tester.pump();
    api.latest.add({
      'batteryPercent': 15,
      'charging': false,
      'observedAt': 1000,
      'receivedAt': 1000,
    });
    api.events.add({
      'episode-1': {
        'createdAt': 1000,
        'severity': 'critical',
        'acknowledgedAt': <String, dynamic>{},
      },
    });
    api.preferences.add({'enabled': true, 'soundEnabled': false});
    await tester.pump();
    expect(find.text('資料已超過一小時'), findsOneWidget);
    expect(find.text('15%'), findsOneWidget);
    expect(find.text('長輩手機電量非常低'), findsOneWidget);
    expect(find.text('已知道'), findsNothing);
    api.failAck = true;
    await tester.tap(find.text('我知道了'));
    await tester.pump();
    expect(find.textContaining('暫時無法確認'), findsOneWidget);
    expect(find.text('我知道了'), findsOneWidget);
    await tester.ensureVisible(find.text('我的手機播放警報聲'));
    expect(find.byType(SwitchListTile), findsNWidgets(2));
  });

  testWidgets('系統通知未授權時不能把偏好開關誤當已可接收', (tester) async {
    final api = _BatteryApi();
    addTearDown(api.close);
    var asked = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BatteryGuardianPanel(
            api: api,
            hostId: 'grandma',
            notificationStatus: () async => false,
            requestNotification: () async {
              asked = true;
              return true;
            },
          ),
        ),
      ),
    );
    api.consent.add({
      'enabled': true,
      'status': 'enabled',
      'version': 1,
      'disclosureVersion': 2,
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('Android 通知尚未開啟'), findsOneWidget);
    await tester.tap(find.text('開啟 Android 通知'));
    await tester.pumpAndSettle();
    expect(asked, isTrue);
    expect(find.textContaining('Android 通知尚未開啟'), findsNothing);
  });

  testWidgets('三小時未收到長輩資料標疑似離線，只用伺服器時間且不宣稱手機關機', (tester) async {
    final api = _BatteryApi();
    addTearDown(api.close);
    final now = DateTime.utc(2026, 10, 2, 6);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              BatteryGuardianPanel(
                api: api,
                hostId: 'grandma',
                clock: () => now,
                notificationStatus: () async => true,
              ),
            ],
          ),
        ),
      ),
    );
    api.consent.add({
      'enabled': true,
      'status': 'enabled',
      'disclosureVersion': 2,
      'updatedAt': DateTime.utc(2026, 10, 1).millisecondsSinceEpoch,
    });
    await tester.pump();
    api.latest.add({
      'batteryPercent': 61,
      // A recent phone-reported timestamp must not hide server silence.
      'observedAt': DateTime.utc(2026, 10, 2, 5, 55).millisecondsSinceEpoch,
      'receivedAt': DateTime.utc(2026, 10, 2, 2, 59).millisecondsSinceEpoch,
    });
    await tester.pump();
    expect(find.textContaining('疑似離線'), findsOneWidget);
    expect(find.textContaining('最後回報'), findsOneWidget);
    expect(find.textContaining('不能據此判定手機已關機'), findsOneWidget);
    expect(find.text('手機已關機'), findsNothing);
  });

  testWidgets('家人頁保持開啟超過三小時，無新回報時狀態會更新', (tester) async {
    final api = _BatteryApi();
    addTearDown(api.close);
    var now = DateTime.utc(2026, 10, 2, 5, 59);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BatteryGuardianPanel(
            api: api,
            hostId: 'grandma',
            clock: () => now,
            notificationStatus: () async => true,
          ),
        ),
      ),
    );
    api.consent.add({
      'enabled': true,
      'status': 'enabled',
      'disclosureVersion': 2,
      'updatedAt': DateTime.utc(2026, 10, 1).millisecondsSinceEpoch,
    });
    await tester.pump();
    api.latest.add({
      'batteryPercent': 61,
      'receivedAt': DateTime.utc(2026, 10, 2, 3).millisecondsSinceEpoch,
    });
    await tester.pump();
    expect(find.textContaining('疑似離線'), findsNothing);
    now = DateTime.utc(2026, 10, 2, 6, 1);
    await tester.pump(const Duration(minutes: 2));
    expect(find.textContaining('疑似離線'), findsOneWidget);
  });

  testWidgets('重新同意後三小時仍無第一筆回報才標疑似離線', (tester) async {
    final api = _BatteryApi();
    addTearDown(api.close);
    final now = DateTime.utc(2026, 10, 2, 6);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BatteryGuardianPanel(
            api: api,
            hostId: 'grandma',
            clock: () => now,
            notificationStatus: () async => true,
          ),
        ),
      ),
    );
    api.consent.add({
      'enabled': true,
      'status': 'enabled',
      'disclosureVersion': 2,
      'updatedAt': DateTime.utc(2026, 10, 2, 2).millisecondsSinceEpoch,
    });
    await tester.pump();
    api.latest.add({});
    await tester.pump();
    expect(find.textContaining('疑似離線'), findsOneWidget);
    expect(find.text('61%'), findsNothing);
  });

  testWidgets(
    'old report cannot suppress suspected offline after new consent times out',
    (tester) async {
      final api = _BatteryApi();
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BatteryGuardianPanel(
              api: api,
              hostId: 'grandma',
              clock: () => DateTime.utc(2026, 10, 2, 9),
              notificationStatus: () async => true,
            ),
          ),
        ),
      );
      api.consent.add({
        'enabled': true,
        'status': 'enabled',
        'disclosureVersion': 2,
        'updatedAt': DateTime.utc(2026, 10, 2, 5).millisecondsSinceEpoch,
      });
      await tester.pump();
      api.latest.add({
        'batteryPercent': 15,
        'receivedAt': DateTime.utc(2026, 10, 2, 4).millisecondsSinceEpoch,
      });
      await tester.pump();
      expect(find.text('15%'), findsNothing);
      expect(find.textContaining('疑似離線'), findsOneWidget);
    },
  );

  testWidgets('新同意前的伺服器舊回報不得當作本輪電量顯示', (tester) async {
    final api = _BatteryApi();
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BatteryGuardianPanel(
            api: api,
            hostId: 'grandma',
            clock: () => DateTime.utc(2026, 10, 2, 6),
            notificationStatus: () async => true,
          ),
        ),
      ),
    );
    api.consent.add({
      'enabled': true,
      'status': 'enabled',
      'disclosureVersion': 2,
      'updatedAt': DateTime.utc(2026, 10, 2, 5).millisecondsSinceEpoch,
    });
    await tester.pump();
    api.latest.add({
      'batteryPercent': 15,
      'receivedAt': DateTime.utc(2026, 10, 2, 4).millisecondsSinceEpoch,
    });
    await tester.pump();
    expect(find.text('15%'), findsNothing);
    expect(find.textContaining('尚無本次分享的回報'), findsOneWidget);
  });

  testWidgets('家人從背景回來立即更新疑似離線狀態', (tester) async {
    final api = _BatteryApi();
    addTearDown(api.close);
    var now = DateTime.utc(2026, 10, 2, 5, 59);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BatteryGuardianPanel(
            api: api,
            hostId: 'grandma',
            clock: () => now,
            notificationStatus: () async => true,
          ),
        ),
      ),
    );
    api.consent.add({
      'enabled': true,
      'status': 'enabled',
      'disclosureVersion': 2,
      'updatedAt': DateTime.utc(2026, 10, 1).millisecondsSinceEpoch,
    });
    await tester.pump();
    api.latest.add({
      'batteryPercent': 61,
      'receivedAt': DateTime.utc(2026, 10, 2, 3).millisecondsSinceEpoch,
    });
    await tester.pump();
    expect(find.textContaining('疑似離線'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = DateTime.utc(2026, 10, 2, 6, 10);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.textContaining('疑似離線'), findsOneWidget);
  });
}
