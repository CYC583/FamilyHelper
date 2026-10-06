// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
// Pure companion helpers shared by host and family screens. No I/O.
//
// Reminder replies and moods are only "what grandma pressed"; nothing here
// infers that medicine was or was not taken, and missing days stay visible.
import 'ui/fh_format.dart';

const Duration _taipeiOffset = Duration(hours: 8);

String taipeiDateKey(DateTime instant) =>
    instant.toUtc().add(_taipeiOffset).toIso8601String().substring(0, 10);

class CareReminder {
  final String type;
  final String time;
  final String text;
  final String id;
  final String repeat;
  final String? date;
  final String? voiceId;
  final String author;
  final List<int>? days;
  final String? pausedUntil;
  const CareReminder(
    this.type,
    this.time,
    this.text, {
    this.id = '',
    this.repeat = 'daily',
    this.date,
    this.voiceId,
    this.author = '',
    this.days,
    this.pausedUntil,
  });

  String get key => '$type:$time';

  /// Native delivery key for a Taipei day (matches ReminderItem.keyFor).
  String deliveryKey(String day) =>
      id.isNotEmpty ? '$day:$id' : '$day:$type:$time';
  bool occursOn(String day) {
    if (pausedUntil != null && day.compareTo(pausedUntil!) <= 0) return false;
    if (repeat == 'once') return date == day;
    if (repeat == 'weekly') {
      final d = DateTime.tryParse(day);
      return d != null && (days?.contains(d.weekday) ?? false);
    }
    return true;
  }

  String get title => switch (type) {
    'medicine' => '吃藥',
    'water' => '喝水',
    'rest' => '休息',
    'photo' => '拍照',
    _ => '家人提醒',
  };

  static List<CareReminder> parsePlan(Object? raw) {
    if (raw is! List) return const [];
    final out = <CareReminder>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final type = item['type'], time = item['time'], text = item['text'];
      if (type is! String ||
          time is! String ||
          !const {
            'medicine',
            'water',
            'rest',
            'photo',
            'custom',
          }.contains(type) ||
          !RegExp(r'^(?:[01][0-9]|2[0-3]):[0-5][0-9]$').hasMatch(time)) {
        continue;
      }
      final voice = item['voiceId'];
      out.add(
        CareReminder(
          type,
          time,
          text is String ? text : '',
          id: item['id'] is String ? item['id'] as String : '',
          repeat: const {'once', 'weekly'}.contains(item['repeat'])
              ? item['repeat'] as String
              : 'daily',
          days: item['days'] is List
              ? [
                  for (final d in item['days'] as List)
                    if (d is num) d.toInt(),
                ]
              : null,
          pausedUntil:
              item['pausedUntil'] is String &&
                  (item['pausedUntil'] as String).isNotEmpty
              ? item['pausedUntil'] as String
              : null,
          date: item['date'] is String ? item['date'] as String : null,
          voiceId: voice is String && voice.isNotEmpty ? voice : null,
          author: item['author'] is String ? item['author'] as String : '',
        ),
      );
    }
    out.sort((a, b) => a.time.compareTo(b.time));
    return out;
  }
}

enum ReplyState { upcoming, unconfirmed, done, later, skip }

ReplyState replyState(CareReminder item, String? response, DateTime now) {
  switch (response) {
    case 'done':
      return ReplyState.done;
    case 'later':
      return ReplyState.later;
    case 'skip':
      return ReplyState.skip;
  }
  final wall = now.toUtc().add(_taipeiOffset);
  final minute = wall.hour * 60 + wall.minute;
  final due =
      int.parse(item.time.substring(0, 2)) * 60 +
      int.parse(item.time.substring(3));
  return minute < due ? ReplyState.upcoming : ReplyState.unconfirmed;
}

String replyLabel(CareReminder item, ReplyState state) => switch (state) {
  ReplyState.upcoming => '還沒到時間',
  ReplyState.unconfirmed => '未確認（不代表沒做）',
  ReplyState.done => switch (item.type) {
    'medicine' => '已按「吃了」',
    'water' => '已按「喝了」',
    'rest' => '已按「休息了」',
    _ => '已回覆',
  },
  ReplyState.later => '按了「稍後」',
  ReplyState.skip => '按了「略過」',
};

const moodLabels = {'good': '開心', 'ok': '普通', 'tired': '有點累', 'bad': '不太好'};

class WeekDay {
  final String date;
  final Map<String, String> responses;
  final String? mood;
  final int photos;
  const WeekDay(this.date, this.responses, this.mood, this.photos);
}

class WeeklySummary {
  final List<WeekDay> days;
  final bool repliesShared;
  final bool moodShared;
  const WeeklySummary(this.days, this.repliesShared, this.moodShared);

  /// Days (so far this week) with no reply, mood or photo at all.
  List<String> get emptyDays => [
    for (final d in days)
      if (d.responses.isEmpty && d.mood == null && d.photos == 0) d.date,
  ];

  int count(String response) => days.fold(
    0,
    (sum, d) => sum + d.responses.values.where((v) => v == response).length,
  );

  /// Plain counts only — no score, diagnosis or "everything is fine".
  List<String> lines() => [
    repliesShared
        ? '提醒回覆：按「完成」${count('done')} 次、「稍後」${count('later')} 次、「略過」${count('skip')} 次'
        : '提醒回覆：長輩未分享',
    moodShared
        ? '心情：${days.where((d) => d.mood != null).map((d) => '${d.date.substring(5)} ${moodLabels[d.mood] ?? d.mood}').join('、').ifEmpty('本週沒有記錄')}'
        : '心情：長輩未分享',
    '照片：本週 ${days.fold<int>(0, (s, d) => s + d.photos)} 張',
    emptyDays.isEmpty
        ? '每天都有至少一筆記錄'
        : '沒有任何記錄的日子：${emptyDays.map((d) => d.substring(5)).join('、')}',
  ];
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// Monday–Sunday of the current Taipei week, only up to today.
List<String> weekDates(DateTime now) {
  final wall = now.toUtc().add(_taipeiOffset);
  final today = DateTime.utc(wall.year, wall.month, wall.day);
  final monday = today.subtract(Duration(days: today.weekday - 1));
  return [
    for (var d = monday; !d.isAfter(today); d = d.add(const Duration(days: 1)))
      d.toIso8601String().substring(0, 10),
  ];
}

WeeklySummary buildWeeklySummary({
  required DateTime now,
  required Map<String, Map<String, String>> responsesByDate,
  required Map<String, String> moodByDate,
  required List<String> photoDays,
  required bool repliesShared,
  required bool moodShared,
}) => WeeklySummary(
  [
    for (final date in weekDates(now))
      WeekDay(
        date,
        repliesShared ? responsesByDate[date] ?? const {} : const {},
        moodShared ? moodByDate[date] : null,
        photoDays.where((d) => d == date).length,
      ),
  ],
  repliesShared,
  moodShared,
);

/// Family-side reminder status for today, from facts reported by grandma's
/// phone. "Played" is only the phone's playback result.
String familyReminderStatus({
  required CareReminder item,
  required String today,
  required DateTime now,
  required int planVersion,
  required int? syncedVersion,
  required Map<String, dynamic>? delivery,
}) {
  if (syncedVersion == null || syncedVersion < planVersion) {
    return '長輩手機尚未同步這次修改';
  }
  if (item.pausedUntil != null && today.compareTo(item.pausedUntil!) <= 0) {
    return '暫停到${int.parse(item.pausedUntil!.substring(5, 7))}月${int.parse(item.pausedUntil!.substring(8))}日';
  }
  if (!item.occursOn(today)) {
    return item.repeat == 'once' && item.date != null
        ? '${int.parse(item.date!.substring(5, 7))}月${int.parse(item.date!.substring(8))}日提醒'
        : '今天不提醒';
  }
  final at = delivery?['at'];
  String clock(Object? ms) {
    if (ms is! num) return '';
    return ' ${friendlyTime(ms, now: now, taipei: true)}';
  }

  switch (delivery?['state']) {
    case 'played':
      return '手機回報已播放${clock(at)}';
    case 'text_fallback':
      return '錄音尚未下載，這次改用文字朗讀${clock(at)}';
    case 'silent':
      return '長輩手機靜音，只跳出通知沒出聲${clock(at)}';
    case 'failed':
      return '播放失敗，等待重試';
  }
  final wall = now.toUtc().add(_taipeiOffset);
  final minutes = wall.hour * 60 + wall.minute;
  final due =
      int.parse(item.time.substring(0, 2)) * 60 +
      int.parse(item.time.substring(3));
  return minutes >= due + 15 ? '提醒時間已過，尚未收到播放結果' : '等待播放';
}

/// Grandma-side wording, kept to three plain states.
String hostReminderStatus(
  String? deliveryState,
  CareReminder item,
  DateTime now,
) {
  if (deliveryState == 'played' || deliveryState == 'text_fallback') {
    return '已播放';
  }
  if (deliveryState == 'silent' || deliveryState == 'failed') return '這次沒播出';
  final wall = now.toUtc().add(_taipeiOffset);
  final minutes = wall.hour * 60 + wall.minute;
  final due =
      int.parse(item.time.substring(0, 2)) * 60 +
      int.parse(item.time.substring(3));
  return minutes > due + 60 ? '這次沒播出' : '等等會提醒你';
}
