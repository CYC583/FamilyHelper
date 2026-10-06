// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:familyhelper/app/common/care_companion.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('plan parsing drops malformed rows and sorts by time', () {
    final plan = CareReminder.parsePlan([
      {'type': 'water', 'time': '14:00', 'text': ''},
      {'type': 'medicine', 'time': '08:00', 'text': '早藥'},
      {'type': 'sos', 'time': '09:00'},
      {'type': 'rest', 'time': '9:00'},
      'junk',
    ]);
    expect(plan.map((p) => p.key), ['medicine:08:00', 'water:14:00']);
  });

  test('no reply after the time is unconfirmed, never "missed medicine"', () {
    const pill = CareReminder('medicine', '08:00', '');
    final before = DateTime.utc(2026, 10, 1, 23, 30); // 07:30 Taipei
    final after = DateTime.utc(2026, 10, 2, 1); // 09:00 Taipei
    expect(replyState(pill, null, before), ReplyState.upcoming);
    final state = replyState(pill, null, after);
    expect(state, ReplyState.unconfirmed);
    expect(replyLabel(pill, state), contains('不代表沒做'));
    expect(replyLabel(pill, replyState(pill, 'done', after)), '已按「吃了」');
  });

  test(
    'weekly summary runs Monday to today in Taipei and lists empty days',
    () {
      final friday = DateTime.utc(2026, 10, 2, 4); // Fri 12:00 Taipei
      expect(weekDates(friday), [
        '2026-09-28',
        '2026-09-29',
        '2026-09-30',
        '2026-10-01',
        '2026-10-02',
      ]);
      // Sunday 23:30 UTC is already Monday in Taipei: a new week of one day.
      expect(weekDates(DateTime.utc(2026, 10, 4, 16, 30)), ['2026-10-05']);
      final summary = buildWeeklySummary(
        now: friday,
        responsesByDate: {
          '2026-09-29': {'medicine:08:00': 'done'},
          '2026-10-01': {'medicine:08:00': 'skip', 'water:14:00': 'later'},
        },
        moodByDate: {'2026-10-02': 'good'},
        photoDays: ['2026-09-30'],
        repliesShared: true,
        moodShared: true,
      );
      expect(summary.emptyDays, ['2026-09-28']);
      final text = summary.lines().join('\n');
      expect(text, contains('完成」1 次'));
      expect(text, contains('10-02 開心'));
      expect(text, contains('沒有任何記錄的日子：09-28'));
      expect(text, isNot(contains('正常')));
      expect(text, isNot(contains('分')));
    },
  );

  test('items grandma did not share are labelled, not shown as empty', () {
    final summary = buildWeeklySummary(
      now: DateTime.utc(2026, 10, 2, 4),
      responsesByDate: {
        '2026-10-02': {'medicine:08:00': 'done'},
      },
      moodByDate: {'2026-10-02': 'bad'},
      photoDays: const [],
      repliesShared: false,
      moodShared: false,
    );
    final text = summary.lines().join('\n');
    expect(text, contains('提醒回覆：長輩未分享'));
    expect(text, contains('心情：長輩未分享'));
    expect(text, isNot(contains('不太好')));
  });

  test(
    'family status separates saved, synced, waiting, played and problems',
    () {
      const pill = CareReminder('medicine', '08:00', '', id: 'r-1');
      final before = DateTime.utc(2026, 10, 2, 23, 50); // 07:50 Taipei 10/3
      final late = DateTime.utc(2026, 10, 3, 0, 20); // 08:20 Taipei
      String run(
        DateTime now, {
        int plan = 3,
        int? synced = 3,
        Map<String, dynamic>? d,
      }) => familyReminderStatus(
        item: pill,
        today: '2026-10-03',
        now: now,
        planVersion: plan,
        syncedVersion: synced,
        delivery: d,
      );
      expect(run(before, synced: 2), '長輩手機尚未同步這次修改');
      expect(run(before), '等待播放');
      expect(run(late), '提醒時間已過，尚未收到播放結果');
      expect(
        run(late, d: {'state': 'played', 'at': late.millisecondsSinceEpoch}),
        '手機回報已播放 今天 08:20',
      );
      expect(run(late, d: {'state': 'text_fallback'}), startsWith('錄音尚未下載'));
      expect(run(late, d: {'state': 'failed'}), '播放失敗，等待重試');
      const once = CareReminder(
        'custom',
        '10:00',
        'x',
        id: 'r-2',
        repeat: 'once',
        date: '2026-10-05',
      );
      expect(
        familyReminderStatus(
          item: once,
          today: '2026-10-03',
          now: late,
          planVersion: 1,
          syncedVersion: 1,
          delivery: null,
        ),
        '10月5日提醒',
      );
    },
  );

  test('grandma sees only: 等等會提醒你 / 已播放 / 這次沒播出', () {
    const pill = CareReminder('medicine', '08:00', '');
    expect(
      hostReminderStatus(null, pill, DateTime.utc(2026, 10, 3, 0, 30)),
      '等等會提醒你',
    );
    expect(
      hostReminderStatus(null, pill, DateTime.utc(2026, 10, 3, 1, 30)),
      '這次沒播出',
    );
    expect(
      hostReminderStatus('played', pill, DateTime.utc(2026, 10, 3, 1)),
      '已播放',
    );
    expect(
      hostReminderStatus('silent', pill, DateTime.utc(2026, 10, 3, 1)),
      '這次沒播出',
    );
  });

  test('每週與暫停：只在選定星期出現，暫停期間（含當天）不提醒', () {
    final r = CareReminder.parsePlan([
      {
        'id': 'w',
        'type': 'water',
        'repeat': 'weekly',
        'days': [1, 3],
        'time': '09:00',
        'pausedUntil': '2026-10-05',
      },
    ]).single;
    expect(r.occursOn('2026-10-05'), isFalse, reason: 'Monday but paused');
    expect(r.occursOn('2026-10-07'), isTrue, reason: 'Wednesday');
    expect(r.occursOn('2026-10-08'), isFalse, reason: 'Thursday');
    expect(r.occursOn('2026-10-12'), isTrue);
  });
}
