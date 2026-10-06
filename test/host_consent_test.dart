// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:familyhelper/app/common/firebase_service.dart';
import 'package:familyhelper/app/common/native_bridge.dart';
import 'package:familyhelper/app/host/host_home_page.dart';

class _FakeApi extends FirebaseService {
  final families = StreamController<Map<String, dynamic>>.broadcast();
  final sessions = <String, StreamController<Map<String, dynamic>>>{};
  final ended = <String>[];
  final accepted = <String>[];
  final sentAlerts = <String>[];
  Completer<Map<String, dynamic>>? accepting;

  @override
  String get uid => 'host';

  @override
  Stream<Map<String, dynamic>> family(String hostId) => families.stream;

  @override
  Stream<Map<String, dynamic>> session(String id) =>
      sessions.putIfAbsent(id, StreamController.broadcast).stream;

  @override
  Future<Map<String, dynamic>> call(
    String name, [
    Map<String, dynamic> data = const {},
  ]) async {
    if (name == 'acceptHelp') {
      accepted.add(data['sessionId'] as String);
      return accepting?.future ?? {'ok': true};
    }
    if (name == 'sendAlert') {
      sentAlerts.add(data['type'] as String);
      return {'alertId': 'preview-alert', 'accepted': 1};
    }
    return {'ok': true};
  }

  @override
  Future<void> end(String id, {bool reject = false}) async {
    ended.add('$id:${reject ? 'rejected' : 'ended'}');
  }

  Future<void> close() async {
    await families.close();
    for (final controller in sessions.values) {
      await controller.close();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeApi api;
  late List<String> requested;
  late List<String> cancelled;
  late Map<String, Completer<bool>> consentResults;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = _FakeApi();
    requested = [];
    cancelled = [];
    consentResults = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, (call) async {
          final arguments = call.arguments is Map
              ? Map<String, dynamic>.from(call.arguments as Map)
              : <String, dynamic>{};
          if (call.method == 'requestConsent') {
            final id = arguments['sessionId'] as String;
            requested.add(id);
            return consentResults.putIfAbsent(id, Completer<bool>.new).future;
          }
          if (call.method == 'cancelConsent') {
            final id = arguments['sessionId'] as String;
            cancelled.add(id);
            final result = consentResults[id];
            if (result != null && !result.isCompleted) result.complete(false);
          }
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, null);
    await api.close();
  });

  Future<void> pending(WidgetTester tester, String id) async {
    api.families.add({'activeSessionId': id});
    await tester.pump();
    api.sessions[id]!.add({
      'status': 'pending',
      'clientName': id,
      'expiresAt': DateTime.now().millisecondsSinceEpoch + 60000,
    });
    await tester.pump();
  }

  testWidgets('call button names both grandchildren and sends call alert', (
    tester,
  ) async {
    await tester.pumpWidget(MaterialApp(home: HostHomePage(api: api)));

    final callButton = find.widgetWithText(FilledButton, '呼叫家人');
    expect(callButton, findsOneWidget);
    await tester.tap(callButton);
    await tester.pump();
    expect(api.sentAlerts, ['call']);

    await tester.pumpWidget(const SizedBox());
  });

  for (final size in const [Size(320, 568), Size(360, 640), Size(412, 732)]) {
    testWidgets('${size.width.toInt()}dp 短螢幕與兩倍大字的求助鍵不需滑動', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              padding: const EdgeInsets.only(top: 24, bottom: 24),
              textScaler: const TextScaler.linear(2),
            ),
            child: HostHomePage(api: api),
          ),
        ),
      );
      await tester.pump();

      final callRect = tester.getRect(
        find.widgetWithText(FilledButton, '呼叫家人'),
      );
      final sosRect = tester.getRect(
        find.widgetWithText(FilledButton, 'SOS\n緊急求助'),
      );
      final navRect = tester.getRect(find.byKey(const Key('host-tab-求助')));
      expect(callRect.height, greaterThanOrEqualTo(120));
      expect(sosRect.height, greaterThanOrEqualTo(120));
      expect(sosRect.top, greaterThan(callRect.bottom));
      expect(sosRect.bottom, lessThanOrEqualTo(navRect.top));
    });
  }

  testWidgets('協助中的結束鍵固定在短螢幕底部且長輩可自行結束', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    var ended = false;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 568),
            padding: EdgeInsets.only(top: 24, bottom: 24),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: const SingleChildScrollView(child: SizedBox(height: 1200)),
            bottomNavigationBar: HostEndAssistanceBar(
              onEnd: () => ended = true,
            ),
          ),
        ),
      ),
    );
    final rect = tester.getRect(find.widgetWithText(FilledButton, '結束協助'));
    expect(rect.height, greaterThanOrEqualTo(120));
    expect(rect.bottom, lessThanOrEqualTo(568 - 24));
    await tester.tap(find.text('結束協助'));
    expect(ended, isTrue);
  });

  testWidgets(
    'replaced request closes its own consent and asks once for new session',
    (tester) async {
      await tester.pumpWidget(MaterialApp(home: HostHomePage(api: api)));
      await pending(tester, 'A');
      expect(requested, ['A']);

      await pending(tester, 'B');
      await tester.pump();
      expect(cancelled, contains('A'));
      expect(requested, ['A', 'B']);
      expect(api.accepted, isEmpty);
      expect(api.ended, isEmpty);

      api.sessions['A']!.add({'status': 'pending'});
      await tester.pump();
      expect(requested, ['A', 'B']);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('late acceptance for replaced request cannot start old session', (
    tester,
  ) async {
    api.accepting = Completer<Map<String, dynamic>>();
    await tester.pumpWidget(MaterialApp(home: HostHomePage(api: api)));
    await pending(tester, 'A');
    consentResults['A']!.complete(true);
    await tester.pump();
    expect(api.accepted, ['A']);

    await pending(tester, 'B');
    api.accepting!.complete({'ok': true});
    await tester.pump();
    await tester.pump();
    expect(cancelled, contains('A'));
    expect(api.ended, contains('A:ended'));
    expect(requested, ['A', 'B']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('new request prompts while old acceptHelp remains pending', (
    tester,
  ) async {
    api.accepting = Completer<Map<String, dynamic>>();
    await tester.pumpWidget(MaterialApp(home: HostHomePage(api: api)));
    await pending(tester, 'A');
    consentResults['A']!.complete(true);
    await tester.pump();
    expect(api.accepted, ['A']);

    await pending(tester, 'B');
    expect(requested, ['A', 'B']);
    expect(api.ended, isEmpty);

    api.accepting!.complete({'ok': true});
    await tester.pump();
    expect(cancelled, contains('A'));
    expect(api.ended, contains('A:ended'));
    expect(requested, ['A', 'B']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('resuming while acceptHelp is pending does not ask twice', (
    tester,
  ) async {
    api.accepting = Completer<Map<String, dynamic>>();
    await tester.pumpWidget(MaterialApp(home: HostHomePage(api: api)));
    await pending(tester, 'A');
    consentResults['A']!.complete(true);
    await tester.pump();
    expect(api.accepted, ['A']);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(requested, ['A']);

    await pending(tester, 'B');
    expect(requested, ['A', 'B']);
    api.accepting!.complete({'ok': true});
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('expired pending request closes its native consent', (
    tester,
  ) async {
    await tester.pumpWidget(MaterialApp(home: HostHomePage(api: api)));
    api.families.add({'activeSessionId': 'A'});
    await tester.pump();
    api.sessions['A']!.add({
      'status': 'pending',
      'clientName': 'Alice',
      'expiresAt': DateTime.now().millisecondsSinceEpoch + 50,
    });
    await tester.pump();
    expect(requested, ['A']);
    await tester.pump(const Duration(milliseconds: 100));
    expect(cancelled, contains('A'));
    expect(api.accepted, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
