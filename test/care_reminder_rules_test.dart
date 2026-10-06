// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:familyhelper/app/common/care_reminder_rules.dart';
import 'package:flutter_test/flutter_test.dart';

/// Taiwan has no DST, so a Taipei wall-clock time is UTC+8. Tests build the
/// instant explicitly to stay independent of the machine's time zone.
DateTime taipei(int y, int m, int d, int h, [int min = 0]) =>
    DateTime.utc(y, m, d, h - 8, min);

void main() {
  group('台股盤中判斷', () {
    test('週四 10:00 在盤中', () {
      expect(isTaiwanMarketHours(taipei(2026, 10, 1, 10)), isTrue);
    });

    test('開盤 09:00 起算、13:30 起不再盤中', () {
      expect(isTaiwanMarketHours(taipei(2026, 10, 1, 8, 59)), isFalse);
      expect(isTaiwanMarketHours(taipei(2026, 10, 1, 9)), isTrue);
      expect(isTaiwanMarketHours(taipei(2026, 10, 1, 13, 29)), isTrue);
      expect(isTaiwanMarketHours(taipei(2026, 10, 1, 13, 30)), isFalse);
    });

    test('週六日不是盤中', () {
      expect(isTaiwanMarketHours(taipei(2026, 10, 3, 10)), isFalse); // Sat
      expect(isTaiwanMarketHours(taipei(2026, 10, 4, 10)), isFalse); // Sun
    });

    test('呼叫端傳入的休市日不是盤中', () {
      final closed = {const CalendarDay(2026, 10, 1)};
      expect(
        isTaiwanMarketHours(taipei(2026, 10, 1, 10), closedDays: closed),
        isFalse,
      );
      expect(
        isTaiwanMarketHours(taipei(2026, 10, 2, 10), closedDays: closed),
        isTrue,
      );
    });

    test('以台北日期判斷，不受執行機器時區影響', () {
      // 2026-10-01 01:30 UTC is 09:30 Thursday in Taipei.
      expect(isTaiwanMarketHours(DateTime.utc(2026, 10, 1, 1, 30)), isTrue);
      // 2026-10-01 17:00 UTC is already Friday 01:00 in Taipei: not trading.
      expect(isTaiwanMarketHours(DateTime.utc(2026, 10, 1, 17)), isFalse);
    });

    test('nextMarketCloseAfter 回傳當天 13:30，非盤中回傳 null', () {
      expect(
        nextTaiwanMarketClose(taipei(2026, 10, 1, 10)),
        taipei(2026, 10, 1, 13, 30),
      );
      expect(nextTaiwanMarketClose(taipei(2026, 10, 1, 15)), isNull);
    });
  });

  group('久看休息提醒', () {
    final now = taipei(2026, 10, 1, 15); // after the close

    test('連續亮屏未滿門檻不提醒', () {
      final d = decideRestReminder(
        now: now,
        continuousScreenOn: const Duration(minutes: 89),
      );
      expect(d.action, RestReminderAction.none);
    });

    test('達 90 分鐘提醒', () {
      final d = decideRestReminder(
        now: now,
        continuousScreenOn: const Duration(minutes: 90),
      );
      expect(d.action, RestReminderAction.remindNow);
    });

    test('門檻可由家人設定，但不得低於下限', () {
      final d = decideRestReminder(
        now: now,
        continuousScreenOn: const Duration(minutes: 45),
        threshold: const Duration(minutes: 45),
      );
      expect(d.action, RestReminderAction.remindNow);
      expect(
        () => decideRestReminder(
          now: now,
          continuousScreenOn: const Duration(minutes: 20),
          threshold: const Duration(minutes: 5),
        ),
        throwsArgumentError,
      );
    });

    test('盤中順延到收盤，並告知順延到何時', () {
      final during = taipei(2026, 10, 1, 11);
      final d = decideRestReminder(
        now: during,
        continuousScreenOn: const Duration(minutes: 120),
      );
      expect(d.action, RestReminderAction.deferred);
      expect(d.remindAfter, taipei(2026, 10, 1, 13, 30));
    });

    test('長輩按「稍後」後，在稍後時間前不再提醒', () {
      final d = decideRestReminder(
        now: now,
        continuousScreenOn: const Duration(minutes: 200),
        snoozedUntil: now.add(const Duration(minutes: 15)),
      );
      expect(d.action, RestReminderAction.snoozed);
      expect(d.remindAfter, now.add(const Duration(minutes: 15)));
    });

    test('稍後時間已過就恢復提醒', () {
      final d = decideRestReminder(
        now: now,
        continuousScreenOn: const Duration(minutes: 200),
        snoozedUntil: now.subtract(const Duration(minutes: 1)),
      );
      expect(d.action, RestReminderAction.remindNow);
    });

    test('剛提醒過，冷卻時間內不重複提醒', () {
      final d = decideRestReminder(
        now: now,
        continuousScreenOn: const Duration(minutes: 150),
        lastRemindedAt: now.subtract(const Duration(minutes: 10)),
      );
      expect(d.action, RestReminderAction.none);
    });

    test('冷卻過後才再次提醒', () {
      final d = decideRestReminder(
        now: now,
        continuousScreenOn: const Duration(minutes: 190),
        lastRemindedAt: now.subtract(const Duration(minutes: 31)),
      );
      expect(d.action, RestReminderAction.remindNow);
    });

    test('負值或不合理的時間長度視為無資料，不提醒', () {
      final d = decideRestReminder(
        now: now,
        continuousScreenOn: const Duration(minutes: -5),
      );
      expect(d.action, RestReminderAction.none);
    });

    test('長輩已暫停分享或提醒關閉時不提醒', () {
      final d = decideRestReminder(
        now: now,
        continuousScreenOn: const Duration(minutes: 200),
        enabled: false,
      );
      expect(d.action, RestReminderAction.none);
    });
  });
}
