// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:familyhelper/app/common/firebase_service.dart';
import 'package:familyhelper/app/common/native_bridge.dart';
import 'package:familyhelper/app/host/pairing_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeApi extends FirebaseService {
  final families = StreamController<Map<String, dynamic>>.broadcast();
  int issuedCodes = 0;

  @override
  String get uid => 'grandma';

  @override
  Stream<Map<String, dynamic>> family(String hostId) => families.stream;

  @override
  Future<Map<String, dynamic>> call(
    String name, [
    Map<String, dynamic> data = const {},
  ]) async {
    if (name == 'createPairCode') {
      issuedCodes++;
      return {
        'code': '123456',
        'expiresAt': DateTime.now()
            .add(const Duration(minutes: 5))
            .millisecondsSinceEpoch,
      };
    }
    return {'ok': true};
  }
}

Map<String, dynamic> _family(int count) => {
  'members': {
    for (var index = 0; index < count; index++)
      'family-$index': {'name': '家人 ${index + 1}'},
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeApi api;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = _FakeApi();
  });
  tearDown(() async => api.families.close());

  testWidgets('five can issue a code; six blocks it and clears the old code', (
    tester,
  ) async {
    await tester.pumpWidget(MaterialApp(home: PairingPage(api: api)));
    api.families.add(_family(5));
    await tester.pump();
    expect(find.text('已連結 5／6 位家人'), findsOneWidget);
    expect(find.text('每位家人都需重新產生一組配對碼。'), findsOneWidget);
    final issue = find.widgetWithText(FilledButton, '產生配對碼');
    expect(tester.widget<FilledButton>(issue).onPressed, isNotNull);
    await tester.tap(issue);
    await tester.pumpAndSettle();
    expect(api.issuedCodes, 1);
    expect(find.text('123456'), findsOneWidget);

    api.families.add(_family(6));
    await tester.pump();
    await tester.pump();
    expect(find.text('已連結 6／6 位家人'), findsOneWidget);
    expect(find.text('已額滿，請先解除一位家人。'), findsOneWidget);
    expect(find.text('123456'), findsNothing);
    expect(tester.widget<FilledButton>(issue).onPressed, isNull);
    expect(find.widgetWithText(TextButton, '解除'), findsNWidgets(6));

    api.families.add(_family(5));
    await tester.pump();
    expect(find.text('123456'), findsNothing);
    expect(tester.widget<FilledButton>(issue).onPressed, isNotNull);
    expect(api.issuedCodes, 1);
  });

  testWidgets('a newly paired family member invalidates the displayed code', (
    tester,
  ) async {
    await tester.pumpWidget(MaterialApp(home: PairingPage(api: api)));
    api.families.add(_family(2));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '產生配對碼'));
    await tester.pumpAndSettle();
    expect(find.text('123456'), findsOneWidget);

    api.families.add(_family(3));
    await tester.pump();
    await tester.pump();
    expect(find.text('已連結 3／6 位家人'), findsOneWidget);
    expect(find.text('123456'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '產生配對碼'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('six members remain reachable at 320dp and 200 percent text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 640),
          textScaler: TextScaler.linear(2),
        ),
        child: MaterialApp(home: PairingPage(api: api)),
      ),
    );
    api.families.add(_family(6));
    await tester.pump();
    expect(find.text('已連結 6／6 位家人'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '解除'), findsNWidgets(6));
    await tester.ensureVisible(find.text('家人 6'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('remote tap permission explains Android scope and app limits', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: MaterialApp(home: PairingPage(api: api)),
      ),
    );
    api.families.add(_family(0));
    await tester.pump();
    final permission = find.text('允許遠端點擊');
    await tester.scrollUntilVisible(
      permission,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(find.textContaining('Android 會授予查看視窗內容的能力'), findsOneWidget);
    expect(find.textContaining('不讀取文字或密碼'), findsOneWidget);
    expect(find.textContaining('每次協助仍須長輩親自同意'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('remote tap permission requires an explicit local choice', (
    tester,
  ) async {
    final invoked = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      NativeBridge.channel,
      (MethodCall call) async {
        invoked.add(call.method);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        NativeBridge.channel,
        null,
      ),
    );
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: MaterialApp(home: PairingPage(api: api)),
      ),
    );
    api.families.add(_family(0));
    await tester.pump();
    final permission = find.text('允許遠端點擊');
    await tester.scrollUntilVisible(
      permission,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(permission);
    await tester.pumpAndSettle();

    expect(find.text('遠端點擊權限'), findsOneWidget);
    expect(find.textContaining('查看視窗內容'), findsWidgets);
    expect(find.textContaining('不讀取文字或密碼'), findsWidgets);
    expect(invoked, isEmpty);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('暫不開啟'));
    await tester.pumpAndSettle();
    expect(invoked, isEmpty);

    await tester.tap(permission);
    await tester.pumpAndSettle();
    await tester.tap(find.text('前往手機設定'));
    await tester.pumpAndSettle();
    expect(invoked, ['accessibilitySettings']);
    expect(tester.takeException(), isNull);
  });
}
