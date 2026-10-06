// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.

/// Human-friendly timestamp: 「今天 14:03」「昨天 08:10」「10月3日 21:45」.
/// [value] is milliseconds since epoch; anything else is reported as unknown.
String friendlyTime(dynamic value, {DateTime? now, bool taipei = false}) {
  if (value is! num) return '時間未知';
  const offset = Duration(hours: 8);
  final t = taipei
      ? DateTime.fromMillisecondsSinceEpoch(
          value.toInt(),
          isUtc: true,
        ).add(offset)
      : DateTime.fromMillisecondsSinceEpoch(value.toInt()).toLocal();
  final n = taipei
      ? (now ?? DateTime.now()).toUtc().add(offset)
      : (now ?? DateTime.now()).toLocal();
  final hm =
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  final day = DateTime(t.year, t.month, t.day);
  final today = DateTime(n.year, n.month, n.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return '今天 $hm';
  if (diff == 1) return '昨天 $hm';
  if (t.year != n.year) return '${t.year}年${t.month}月${t.day}日 $hm';
  return '${t.month}月${t.day}日 $hm';
}
