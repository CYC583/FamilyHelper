// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';
import 'dart:typed_data';

import 'package:familyhelper/app/client/client_app_usage_page.dart';
import 'package:familyhelper/app/client/client_location_page.dart';
import 'package:familyhelper/app/common/firebase_service.dart';
import 'package:familyhelper/app/common/native_bridge.dart';
import 'package:familyhelper/app/common/profile_page.dart';
import 'package:familyhelper/app/host/host_sharing_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

class _Api extends FirebaseService {
  final streams = <String, StreamController<Map<String, dynamic>>>{};
  final calls = <(String, Map<String, dynamic>)>[];
  Object? fail;

  StreamController<Map<String, dynamic>> at(String path) => streams.putIfAbsent(
    path,
    StreamController<Map<String, dynamic>>.broadcast,
  );

  @override
  String get uid => 'me';

  @override
  Stream<Map<String, dynamic>> watch(String path) => at(path).stream;

  @override
  Future<Map<String, dynamic>> call(
    String name, [
    Map<String, dynamic> data = const {},
  ]) async {
    calls.add((name, data));
    if (fail != null) throw fail!;
    if (name.startsWith('set') && name.endsWith('Sharing')) {
      return {'enabled': data['enabled'], 'version': 3};
    }
    return {'ok': true};
  }

  void close() {
    for (final s in streams.values) {
      s.close();
    }
  }
}

const _on = {
  'enabled': true,
  'status': 'enabled',
  'disclosureVersion': 1,
  'version': 1,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('定位分頁', () {
    Future<_Api> open(
      WidgetTester tester, {
      List<(double, double)>? nav,
    }) async {
      final api = _Api();
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ClientLocationPage(
              api: api,
              hostId: 'g',
              hostName: '阿嬤',
              showMap: false,
              clock: () =>
                  DateTime.fromMillisecondsSinceEpoch(1_790_000_600_000),
              navigate: (lat, lng) async {
                nav?.add((lat, lng));
                return true;
              },
            ),
          ),
        ),
      );
      return api;
    }

    testWidgets('長輩沒開啟時清楚說明，不顯示位置', (tester) async {
      final api = await open(tester);
      api.at('care/g/location/consent').add({});
      await tester.pump();
      expect(find.textContaining('阿嬤還沒有開啟位置分享'), findsOneWidget);
      expect(find.byKey(const Key('location-avatar')), findsNothing);
      api.at('care/g/location/consent').add({
        'enabled': false,
        'status': 'paused',
      });
      await tester.pump();
      expect(find.text('阿嬤已暫停位置分享'), findsOneWidget);
    });

    testWidgets('點頭貼：讓手機響（先確認）、導航、重新定位', (tester) async {
      final nav = <(double, double)>[];
      final api = await open(tester, nav: nav);
      api.at('care/g/location/consent').add(_on);
      await tester.pump();
      api.at('care/g/location/latest').add({
        'lat': 25.03,
        'lng': 121.56,
        'accuracy': 20,
        'at': 1_790_000_000_000,
      });
      await tester.pump();
      expect(find.textContaining('10 分鐘前'), findsOneWidget);

      await tester.tap(find.byKey(const Key('location-avatar')));
      await tester.pumpAndSettle();
      expect(find.text('誤差約 20 公尺'), findsOneWidget);
      await tester.tap(find.byKey(const Key('location-ring')));
      await tester.pumpAndSettle();
      expect(api.calls, isEmpty, reason: 'asks first');
      await tester.tap(find.widgetWithText(FilledButton, '讓手機響'));
      await tester.pumpAndSettle();
      expect(api.calls.single.$1, 'ringHostPhone');
      expect(api.calls.single.$2['hostId'], 'g');
      expect(find.textContaining('會響 10 秒'), findsOneWidget);

      await tester.tap(find.byKey(const Key('location-avatar')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('location-navigate')));
      await tester.pumpAndSettle();
      expect(nav, [(25.03, 121.56)]);

      await tester.tap(find.byKey(const Key('location-avatar')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('location-locate')));
      await tester.pumpAndSettle();
      expect(api.calls.last.$1, 'requestHostUpdate');
      expect(api.calls.last.$2['kind'], 'locate');
    });

    testWidgets('長輩暫停後立刻不顯示舊位置', (tester) async {
      final api = await open(tester);
      api.at('care/g/location/consent').add(_on);
      await tester.pump();
      api.at('care/g/location/latest').add({'lat': 1.0, 'lng': 2.0, 'at': 1});
      await tester.pump();
      expect(find.byKey(const Key('location-avatar')), findsOneWidget);
      api.at('care/g/location/consent').add({
        'enabled': false,
        'status': 'paused',
      });
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('location-avatar')), findsNothing);
    });
  });

  testWidgets('手機使用時間：依時間排序、顯示合計，可切換日期與更新', (tester) async {
    final api = _Api();
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: ClientAppUsagePage(
          api: api,
          hostId: 'g',
          clock: () => DateTime.utc(2026, 10, 3, 4),
        ),
      ),
    );
    api.at('care/g/appUsage/consent').add(_on);
    await tester.pump();
    api.at('care/g/appUsage/days/2026-10-03').add({
      'apps': [
        {'name': 'YouTube', 'minutes': 95},
        {'name': 'LINE', 'minutes': 30},
      ],
      'total': 125,
    });
    await tester.pump();
    expect(find.text('合計 2 小時 5 分'), findsOneWidget);
    expect(find.text('1 小時 35 分'), findsOneWidget);
    expect(find.text('30 分鐘'), findsOneWidget);
    await tester.tap(find.byKey(const Key('usage-refresh')));
    await tester.pump();
    expect(api.calls.single.$2['kind'], 'usage');
    await tester.tap(find.byKey(const Key('usage-day-2026-10-02')));
    await tester.pump();
    expect(find.text('這天沒有紀錄'), findsOneWidget);
  });

  testWidgets('我的名字與頭貼：選照片裁成小圖，按儲存才送出', (tester) async {
    final api = _Api();
    addTearDown(api.close);
    final photo = Uint8List.fromList(
      img.encodeJpg(img.Image(width: 400, height: 300)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ProfilePage(
          api: api,
          hostId: 'g',
          currentName: '小明',
          pick: (source) async => photo,
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('profile-gallery')));
    await tester.pump();
    expect(api.calls, isEmpty);
    expect(find.textContaining('還沒儲存'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('profile-name')), '阿明');
    await tester.tap(find.byKey(const Key('profile-save')));
    await tester.pumpAndSettle();
    final call = api.calls.single;
    expect(call.$1, 'setProfile');
    expect(call.$2['name'], '阿明');
    final avatar = call.$2['avatarBase64'] as String;
    expect(avatar.length, lessThan(58_000));
    expect(find.textContaining('已儲存'), findsOneWidget);
    expect(avatarBase64(photo), isNotNull);
  });

  testWidgets('長輩開啟分享：一定先跳本機說明；不同意就不送出', (tester) async {
    final native = <String>[];
    var agree = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      NativeBridge.channel,
      (call) async {
        native.add(call.method);
        if (call.method == 'usageSnapshot') {
          return {
            'enabled': native.contains('usageEnable'),
            'permission': true,
          };
        }
        if (call.method == 'sharingPrepareConsent') return agree;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        NativeBridge.channel,
        null,
      ),
    );
    final api = _Api();
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: HostSharingPage(api: api, kind: 'usage'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sharing-agree')));
    await tester.pumpAndSettle();
    expect(api.calls, isEmpty, reason: 'declined locally');
    agree = true;
    await tester.tap(find.byKey(const Key('sharing-agree')));
    await tester.pumpAndSettle();
    expect(api.calls.single.$1, 'setAppUsageSharing');
    expect(
      native,
      containsAllInOrder(['sharingPrepareConsent', 'usageEnable']),
    );
    expect(find.text('分享中 ✓'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sharing-stop')));
    await tester.pumpAndSettle();
    expect(
      native.indexOf('usageDisable'),
      greaterThan(native.indexOf('usageEnable')),
    );
    expect(api.calls.last.$2['enabled'], false);
  });
}
