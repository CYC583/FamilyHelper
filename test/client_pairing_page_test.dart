// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:familyhelper/app/client/pairing_client_page.dart';
import 'package:familyhelper/app/common/firebase_service.dart';
import 'package:familyhelper/app/common/ui/fh_theme.dart';
import 'package:familyhelper/app/common/constants.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeApi extends FirebaseService {
  final calls = <String>[];
  Object? failWith;

  @override
  Future<Map<String, dynamic>> call(
    String name, [
    Map<String, dynamic> data = const {},
  ]) async {
    calls.add(name);
    if (failWith != null && name == 'pairDevice') throw failWith!;
    return {'ok': true};
  }
}

Future<_FakeApi> _open(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final api = _FakeApi();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFhTheme(AppRole.client),
      home: PairingClientPage(api: api),
    ),
  );
  return api;
}

void main() {
  testWidgets('空白送出時在欄位旁指出缺什麼，不呼叫後端', (tester) async {
    final api = await _open(tester);
    await tester.tap(find.text('配對'));
    await tester.pump();

    expect(find.text('請填寫長輩認得的名字'), findsOneWidget);
    expect(find.text('配對碼是六位數字'), findsOneWidget);
    expect(find.byKey(const Key('pair-error')), findsNothing);
    expect(api.calls, isEmpty);
  });

  testWidgets('修正欄位後清除該欄錯誤，送出後依序註冊與配對', (tester) async {
    final api = await _open(tester);
    await tester.tap(find.text('配對'));
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, '小明');
    await tester.pump();
    expect(find.text('請填寫長輩認得的名字'), findsNothing);

    await tester.enterText(find.byType(TextField).last, '12a3456');
    await tester.pump();
    expect(find.text('123456'), findsOneWidget, reason: '只接受數字且最多六位');

    await tester.tap(find.text('配對'));
    await tester.pumpAndSettle();
    expect(api.calls, ['registerDevice', 'pairDevice']);
    expect(find.byKey(const Key('pair-error')), findsNothing);
  });

  testWidgets('後端拒絕時顯示錯誤並可再按一次', (tester) async {
    final api = await _open(tester);
    api.failWith = Exception('配對碼已過期');
    await tester.enterText(find.byType(TextField).first, '小明');
    await tester.enterText(find.byType(TextField).last, '654321');
    await tester.tap(find.text('配對'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pair-error')), findsOneWidget);
    expect(find.textContaining('配對碼已過期'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNotNull);
  });
}
