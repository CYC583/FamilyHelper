// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:familyhelper/app/client/client_home_page.dart';
import 'package:familyhelper/app/common/firebase_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Api extends FirebaseService {
  final streams = <String, StreamController<Map<String, dynamic>>>{};
  final families = StreamController<Map<String, dynamic>>.broadcast();

  StreamController<Map<String, dynamic>> at(String path) => streams.putIfAbsent(
    path,
    StreamController<Map<String, dynamic>>.broadcast,
  );

  @override
  String get uid => 'me';

  @override
  Stream<Map<String, dynamic>> watch(String path) => at(path).stream;

  @override
  Stream<Map<String, dynamic>> family(String hostId) => families.stream;

  void close() {
    for (final s in streams.values) {
      s.close();
    }
    families.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('長輩狀態：摘要一行一項，點開看詳細；聊天有未讀數，點開後清除', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = _Api();
    addTearDown(api.close);
    await tester.pumpWidget(MaterialApp(home: ClientHomePage(api: api)));
    api.at('core/links/me').add({'hostId': 'g'});
    await tester.pump();
    api.families.add({
      'members': {
        'me': {'name': '我'},
        'bro': {'name': '哥哥'},
      },
    });
    await tester.pump();
    api.at('care/g/battery/latest').add({
      'batteryPercent': 15,
      'charging': false,
    });
    api.at('care/g/companion/sound/latest').add({
      'ringer': 'silent',
      'dnd': false,
      'mediaZero': false,
    });
    api.at('care/g/places/consent').add({'enabled': false});
    final now = DateTime.now().millisecondsSinceEpoch;
    api.at('care/g/messages/items').add({
      'm1': {'authorId': 'g', 'kind': 'text', 'text': '吃飽了', 'createdAt': now},
      'm2': {'authorId': 'me', 'kind': 'text', 'text': '好', 'createdAt': now},
    });
    await tester.pump();

    expect(find.text('15%'), findsOneWidget);
    expect(find.text('鈴聲靜音'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('status-place')),
        matching: find.text('尚未開啟'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('status-usage')),
        matching: find.text('尚未開啟'),
      ),
      findsOneWidget,
    );
    expect(find.text('協助操作長輩的手機（需長輩同意）'), findsOneWidget);
    final badge = tester.widget<Badge>(
      find.byKey(const Key('client-chat-badge')),
    );
    expect(badge.isLabelVisible, isTrue);
    expect(find.text('1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('status-battery')));
    await tester.pumpAndSettle();
    expect(find.text('電量守護'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('client-tab-陪伴')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('client-tab-守護')));
    await tester.pump();
    expect(
      tester
          .widget<Badge>(find.byKey(const Key('client-chat-badge')))
          .isLabelVisible,
      isFalse,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('chat_seen_at'), now);
  });

  testWidgets('360dp、200% 字級仍可讀取全部底部分頁名稱', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = _Api();
    addTearDown(api.close);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(360, 800),
          textScaler: TextScaler.linear(2),
        ),
        child: ClientHomePage(api: api),
      ),
    ));
    api.at('core/links/me').add({'hostId': 'g'});
    await tester.pump();
    api.families.add({'members': {'me': {'name': '我'}}});
    await tester.pump();
    final destination = tester.widget<NavigationDestination>(
      find.byKey(const Key('client-tab-守護')),
    );
    expect(destination.label, '狀態');
    expect(tester.takeException(), isNull);
  });
}
