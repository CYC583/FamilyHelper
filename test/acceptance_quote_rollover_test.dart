// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:familyhelper/app/host/host_today_page.dart';
import 'package:familyhelper/app/common/daily_quote.dart';
import 'package:familyhelper/app/common/daily_quote_library.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'daily quote advances at Taipei midnight even with no weather city',
    (tester) async {
      var now = DateTime.utc(2026, 10, 2, 15, 59, 50);
      String quote(DateTime time) => pickDailyQuote(
        date: time.toUtc().add(const Duration(hours: 8)),
        seed: 'grandma',
        library: builtInQuotes,
        pendingFamily: [],
      ).text;
      final oldQuote = quote(now);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HostTodayPage(hostUid: 'grandma', clock: () => now),
          ),
        ),
      );
      expect(find.text(oldQuote), findsOneWidget);
      now = DateTime.utc(2026, 10, 2, 16, 0, 1);
      final newQuote = quote(now);
      expect(newQuote, isNot(oldQuote));
      await tester.pump(const Duration(seconds: 11));
      await tester.pumpAndSettle();
      expect(
        find.text(newQuote),
        findsOneWidget,
        reason: '每日一句 cannot stay yesterday merely because weather is unset',
      );
      expect(find.text(oldQuote), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
