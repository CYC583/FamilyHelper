// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:familyhelper/app/common/firebase_service.dart';
import 'package:familyhelper/app/host/host_home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Api extends FirebaseService {
  final streams = <String, StreamController<Map<String, dynamic>>>{};
  final calls = <(String, Map<String, dynamic>)>[];
  Map<String, dynamic> alertResult = const {'accepted': 0};
  StreamController<Map<String, dynamic>> at(String p) =>
      streams.putIfAbsent(p, StreamController<Map<String, dynamic>>.broadcast);
  @override
  String get uid => 'grandma';
  @override
  Stream<Map<String, dynamic>> watch(String path) => at(path).stream;
  @override
  Stream<Map<String, dynamic>> family(String hostId) => at('family').stream;
  @override
  Stream<Map<String, dynamic>> session(String id) => at('session/$id').stream;
  @override
  Future<Map<String, dynamic>> call(
    String name, [
    Map<String, dynamic> data = const {},
  ]) async {
    calls.add((name, data));
    if (name == 'sendAlert') return alertResult;
    return {'ok': true};
  }

  void close() {
    for (final s in streams.values) {
      s.close();
    }
  }
}

void main() {
  final spoken = <String>[];
  final native = <MethodCall>[];
  setUp(() {
    spoken.clear();
    native.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('familyhelper/native'), (
          call,
        ) async {
          native.add(call);
          if (call.method == 'speakText') {
            spoken.add(call.arguments['text'] as String);
          }
          if (call.method == 'screenOnDuration') {
            return 0;
          }
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter.baseflow.com/geolocator'),
          (call) async => call.method == 'checkPermission' ? 0 : null,
        );
  });

  testWidgets('no answer offers calling a confirmed family number and retry', (
    tester,
  ) async {
    final api = _Api();
    addTearDown(api.close);
    await tester.pumpWidget(MaterialApp(home: HostHomePage(api: api)));
    api.at('care/grandma/contacts').add({
      'bro': {'name': '哥哥', 'phone': '0912345678', 'confirmed': true},
      'sis': {'name': '妹妹', 'phone': '0987654321', 'confirmed': false},
    });
    await tester.pump();
    await tester.tap(find.text('呼叫家人'));
    await tester.pump();
    expect(spoken.first, '正在聯絡家人。', reason: 'no claim before the result');
    await tester.pumpAndSettle();
    expect(find.text('沒有送出'), findsOneWidget);
    expect(find.byKey(const Key('help-dial-bro')), findsOneWidget);
    expect(
      find.byKey(const Key('help-dial-sis')),
      findsNothing,
      reason: 'unconfirmed number hidden',
    );
    await tester.tap(find.byKey(const Key('help-dial-bro')));
    await tester.pump();
    final dial = native.lastWhere((c) => c.method == 'dialNumber');
    expect(dial.arguments['number'], '0912345678');
    expect(find.byKey(const Key('help-retry')), findsOneWidget);
  });

  testWidgets('while ringing grandma can cancel the call', (tester) async {
    final api = _Api()
      ..alertResult = {'accepted': 2, 'sessionId': 's1', 'alertId': 'a1'};
    addTearDown(api.close);
    await tester.pumpWidget(MaterialApp(home: HostHomePage(api: api)));
    await tester.tap(find.text('呼叫家人'));
    await tester.pumpAndSettle();
    expect(find.text('正在聯絡家人…'), findsOneWidget);
    await tester.tap(find.byKey(const Key('help-cancel')));
    await tester.pumpAndSettle();
    expect(api.calls.last.$1, 'cancelHostCall');
    expect(api.calls.last.$2['sessionId'], 's1');
    expect(find.byKey(const Key('help-panel')), findsNothing);
  });

  testWidgets('inline notice never covers SOS and SOS still sends alert', (
    tester,
  ) async {
    final api = _Api();
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: HostHomePage(api: api, initialNotice: '推播尚未啟用'),
      ),
    );
    expect(find.text('推播尚未啟用'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    await tester.tap(find.text('SOS\n緊急求助'));
    await tester.pumpAndSettle();
    expect(
      api.calls.any(
        (entry) => entry.$1 == 'sendAlert' && entry.$2['type'] == 'sos',
      ),
      isTrue,
      reason: api.calls.toString(),
    );
  });
}
