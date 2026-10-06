// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:familyhelper/app/common/ui/fh_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 6, 15, 0);
  int ms(DateTime d) => d.millisecondsSinceEpoch;

  test('friendlyTime uses 今天／昨天 and short dates', () {
    expect(friendlyTime(ms(DateTime(2026, 10, 6, 9, 5)), now: now), '今天 09:05');
    expect(
      friendlyTime(ms(DateTime(2026, 10, 5, 23, 59)), now: now),
      '昨天 23:59',
    );
    expect(
      friendlyTime(ms(DateTime(2026, 10, 1, 8, 0)), now: now),
      '10月1日 08:00',
    );
    expect(
      friendlyTime(ms(DateTime(2025, 12, 31, 20, 30)), now: now),
      '2025年12月31日 20:30',
    );
  });

  test('friendlyTime reports unknown for missing values', () {
    expect(friendlyTime(null, now: now), '時間未知');
    expect(friendlyTime('x', now: now), '時間未知');
  });

  test('Taipei timestamps use Taipei calendar even with UTC clock', () {
    final taipeiNow = DateTime.utc(2026, 10, 5, 17);
    final event = DateTime.utc(2026, 10, 5, 16, 5);
    expect(
      friendlyTime(event.millisecondsSinceEpoch, now: taipeiNow, taipei: true),
      '今天 00:05',
    );
  });
}
