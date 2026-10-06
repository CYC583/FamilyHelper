// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:familyhelper/app/common/bootstrap.dart';
import 'package:familyhelper/app/common/constants.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('長輩第一次開啟先看到指引，不先進入設定或權限流程', (tester) async {
    await tester.pumpWidget(const FamilyApp(role: AppRole.host));
    await tester.pumpAndSettle();

    expect(find.text('長輩版使用指引'), findsOneWidget);
    expect(find.byKey(const Key('startup-not-configured')), findsNothing);
    expect(find.byKey(const Key('onboarding-next')), findsOneWidget);
    expect(find.byKey(const Key('onboarding-skip')), findsOneWidget);
  });

  testWidgets('略過只記錄本機指引完成，重新開啟不再顯示', (tester) async {
    await tester.pumpWidget(const FamilyApp(role: AppRole.host));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('onboarding-skip')));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('onboarding_host_v1'), isTrue);
    expect(find.text('長輩版使用指引'), findsNothing);
    expect(find.byKey(const Key('startup-not-configured')), findsOneWidget);
    expect(find.textContaining('python3 tool/setup.py'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const FamilyApp(role: AppRole.host));
    await tester.pumpAndSettle();
    expect(find.text('長輩版使用指引'), findsNothing);
  });

  testWidgets('家人指引與長輩指引分開記錄', (tester) async {
    SharedPreferences.setMockInitialValues({'onboarding_host_v1': true});
    await tester.pumpWidget(const FamilyApp(role: AppRole.client));
    await tester.pumpAndSettle();

    expect(find.text('家人版使用指引'), findsOneWidget);
  });

  testWidgets('短螢幕與兩倍字級仍看得到下一步及略過', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(2)),
        child: FamilyApp(role: AppRole.host),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    for (final key in ['onboarding-next', 'onboarding-skip']) {
      final rect = tester.getRect(find.byKey(Key(key)));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(568));
    }
  });
}
