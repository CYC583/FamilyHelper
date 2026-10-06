// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
// Pure decision rules for the grandmother-side "rest your eyes" reminder.
//
// No I/O, clock reads or platform calls: the caller supplies the current
// instant and the continuous screen-on duration (derived from screen on/off
// events only, never from which app is open). This keeps the policy testable
// and keeps the product promise that no app names are collected.

/// A calendar date in Taiwan, used for caller-supplied market holidays.
/// Exchange holidays and typhoon closures cannot be derived from a rule, so
/// the caller owns that list; an empty set simply means "no known closures".
class CalendarDay {
  final int year;
  final int month;
  final int day;

  const CalendarDay(this.year, this.month, this.day);

  @override
  bool operator ==(Object other) =>
      other is CalendarDay &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() => '$year-$month-$day';
}

const Duration _taipeiOffset = Duration(hours: 8);
const int _marketOpenMinute = 9 * 60;
const int _marketCloseMinute = 13 * 60 + 30;

/// Taiwan has no daylight saving, so Taipei wall-clock time is UTC+8 and is
/// independent of the device's configured time zone.
DateTime _taipeiWallClock(DateTime instant) =>
    instant.toUtc().add(_taipeiOffset);

/// Whether [instant] falls inside regular Taiwan stock-market trading hours:
/// Monday to Friday, 09:00 up to but excluding 13:30 Taipei time, and not on a
/// day in [closedDays].
bool isTaiwanMarketHours(
  DateTime instant, {
  Set<CalendarDay> closedDays = const {},
}) {
  final wall = _taipeiWallClock(instant);
  if (wall.weekday == DateTime.saturday || wall.weekday == DateTime.sunday) {
    return false;
  }
  if (closedDays.contains(CalendarDay(wall.year, wall.month, wall.day))) {
    return false;
  }
  final minuteOfDay = wall.hour * 60 + wall.minute;
  return minuteOfDay >= _marketOpenMinute && minuteOfDay < _marketCloseMinute;
}

/// The instant (UTC) at which the current trading session ends, or null when
/// [instant] is not inside trading hours.
DateTime? nextTaiwanMarketClose(
  DateTime instant, {
  Set<CalendarDay> closedDays = const {},
}) {
  if (!isTaiwanMarketHours(instant, closedDays: closedDays)) return null;
  final wall = _taipeiWallClock(instant);
  return DateTime.utc(
    wall.year,
    wall.month,
    wall.day,
    _marketCloseMinute ~/ 60,
    _marketCloseMinute % 60,
  ).subtract(_taipeiOffset);
}

enum RestReminderAction {
  /// Nothing to do now.
  none,

  /// Show the rest reminder now.
  remindNow,

  /// Due, but held back until [RestReminderDecision.remindAfter] because the
  /// market is open and this is a non-urgent reminder.
  deferred,

  /// The user chose "later"; wait until [RestReminderDecision.remindAfter].
  snoozed,
}

class RestReminderDecision {
  final RestReminderAction action;
  final DateTime? remindAfter;

  const RestReminderDecision(this.action, [this.remindAfter]);
}

const Duration defaultRestThreshold = Duration(minutes: 90);
const Duration minimumRestThreshold = Duration(minutes: 15);
const Duration defaultRestCooldown = Duration(minutes: 30);

/// Decide whether to show the continuous-viewing rest reminder.
///
/// Applies only to non-urgent rest/water style reminders. Medication
/// reminders, calls and SOS must never be routed through this function's
/// market-hours deferral.
///
/// Throws [ArgumentError] when [threshold] is below [minimumRestThreshold];
/// a too-small family-configured value would nag constantly.
RestReminderDecision decideRestReminder({
  required DateTime now,
  required Duration continuousScreenOn,
  Duration threshold = defaultRestThreshold,
  Duration cooldown = defaultRestCooldown,
  DateTime? snoozedUntil,
  DateTime? lastRemindedAt,
  bool enabled = true,
  Set<CalendarDay> closedDays = const {},
}) {
  if (threshold < minimumRestThreshold) {
    throw ArgumentError.value(
      threshold,
      'threshold',
      '提醒門檻不得少於 ${minimumRestThreshold.inMinutes} 分鐘',
    );
  }
  if (!enabled) return const RestReminderDecision(RestReminderAction.none);
  // A negative duration means the source data is unusable, not "no viewing".
  if (continuousScreenOn.isNegative || continuousScreenOn < threshold) {
    return const RestReminderDecision(RestReminderAction.none);
  }
  if (snoozedUntil != null && now.isBefore(snoozedUntil)) {
    return RestReminderDecision(RestReminderAction.snoozed, snoozedUntil);
  }
  if (lastRemindedAt != null && now.difference(lastRemindedAt) < cooldown) {
    return const RestReminderDecision(RestReminderAction.none);
  }
  final close = nextTaiwanMarketClose(now, closedDays: closedDays);
  if (close != null) {
    return RestReminderDecision(RestReminderAction.deferred, close);
  }
  return const RestReminderDecision(RestReminderAction.remindNow);
}
