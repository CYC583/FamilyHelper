// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:familyhelper/app/host/host_today_page.dart';
import 'package:familyhelper/app/common/daily_quote.dart';
import 'package:familyhelper/app/common/daily_quote_library.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final size in [
    const Size(320, 568),
    const Size(360, 640),
    const Size(412, 732),
    const Size(568, 320),
  ]) {
    testWidgets('Today card remains usable at $size with 200% text', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final longest = builtInQuotes.reduce(
        (a, b) => a.length > b.length ? a : b,
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: HostTodayPage(
              hostUid: 'review',
              now: DateTime.utc(2026, 10, 2),
              pendingFamily: [
                FamilyQuote(
                  id: 'layout',
                  text: longest,
                  author: '家人',
                  createdAt: DateTime.utc(2026, 10, 1),
                ),
              ],
            ),
            bottomNavigationBar: const SizedBox(height: 80),
          ),
        ),
      );
      expect(
        tester.takeException(),
        isNull,
        reason: 'Legal quote must remain readable with system large text',
      );
      expect(find.text(longest), findsOneWidget);
    });
  }
}
