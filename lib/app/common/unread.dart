// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_service.dart';

/// Messages from someone else newer than the last time this phone opened the
/// chat. Stored only on this phone.
int unreadCount(Map<String, dynamic> items, String self, int seenAt) => items
    .values
    .map(asMap)
    .where(
      (m) =>
          m['authorId'] is String &&
          m['authorId'] != self &&
          ((m['createdAt'] as num?) ?? 0) > seenAt,
    )
    .length;

int newestMessageAt(Map<String, dynamic> items) => items.values
    .map((v) => (asMap(v)['createdAt'] as num?)?.toInt() ?? 0)
    .fold(0, (a, b) => a > b ? a : b);

const _seenKey = 'chat_seen_at';

Future<int> loadChatSeen() async {
  try {
    return (await SharedPreferences.getInstance()).getInt(_seenKey) ?? 0;
  } catch (_) {
    return 0;
  }
}

Future<void> saveChatSeen(int at) async {
  try {
    await (await SharedPreferences.getInstance()).setInt(_seenKey, at);
  } catch (_) {}
}
