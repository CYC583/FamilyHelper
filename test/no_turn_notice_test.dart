// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:familyhelper/app/client/remote_view_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('without TURN the family sees the cross-network limitation', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: NoTurnNotice(hasTurn: false))),
    );
    expect(find.text('這次未取得跨網路轉接，遠端協助可能無法連線；請改用電話聯絡。'), findsOneWidget);
  });

  testWidgets('with TURN the warning is not shown', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: NoTurnNotice(hasTurn: true))),
    );
    expect(find.textContaining('未取得跨網路轉接'), findsNothing);
  });
}
