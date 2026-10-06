// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'firebase_service.dart';
import 'ui/fh_format.dart';

/// Photo metadata from `listCarePhotos`.
class CarePhoto {
  final String mediaId, authorId, day;
  final int createdAt;
  const CarePhoto(this.mediaId, this.authorId, this.day, this.createdAt);

  static List<CarePhoto> parseList(Object? raw) {
    if (raw is! List) throw const FormatException('照片清單格式錯誤');
    final photos = <CarePhoto>[];
    for (final item in raw.map(asMap)) {
      final id = item['mediaId'];
      if (id is! String || id.isEmpty) {
        throw const FormatException('照片資料不完整');
      }
      photos.add(
        CarePhoto(
          id,
          item['authorId'] as String? ?? '',
          item['day'] as String? ?? '',
          (item['createdAt'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    photos.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return photos;
  }
}

/// Downloads private photos through the callable, validates them as square
/// JPEGs, and keeps a few in memory. At most two downloads run at once so a
/// 30-day album never fetches every photo together. Callers must [clear] when
/// sharing is paused so a cached copy cannot reappear.
class PhotoLoader {
  PhotoLoader._();
  static const _maxCached = 16, _maxParallel = 2;
  static final _cache = <String, Uint8List>{};
  static final _inFlight = <String, Future<Uint8List>>{};
  static int _running = 0;
  static final _waiting = Queue<Completer<void>>();
  static int _epoch = 0;

  static String _key(String hostId, String mediaId) => '$hostId/$mediaId';

  static Uint8List? cached(String hostId, String mediaId) =>
      _cache[_key(hostId, mediaId)];

  static void clear() {
    _epoch++;
    _cache.clear();
    _inFlight.clear();
  }

  static Future<Uint8List> load(
    FirebaseService api,
    String hostId,
    String mediaId,
  ) {
    final key = _key(hostId, mediaId);
    final hit = _cache.remove(key);
    if (hit != null) {
      _cache[key] = hit;
      return Future.value(hit);
    }
    return _inFlight[key] ??= _fetch(api, hostId, mediaId, key, _epoch)
        .whenComplete(() {
          // A block body: returning the removed future here would make this
          // future wait on itself forever.
          _inFlight.remove(key);
        });
  }

  static Future<Uint8List> _fetch(
    FirebaseService api,
    String hostId,
    String mediaId,
    String key,
    int epoch,
  ) async {
    if (_running >= _maxParallel) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _running++;
    try {
      final result = await api.call('getCarePhoto', {
        'hostId': hostId,
        'mediaId': mediaId,
      });
      final bytes = validate(result, mediaId);
      if (epoch == _epoch) {
        _cache[key] = bytes;
        while (_cache.length > _maxCached) {
          _cache.remove(_cache.keys.first);
        }
      }
      return bytes;
    } finally {
      _running--;
      if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
    }
  }

  static Uint8List validate(Map<String, dynamic> result, String mediaId) {
    final encoded = result['jpegBase64'];
    if ((result['mediaId'] != null && result['mediaId'] != mediaId) ||
        encoded is! String ||
        encoded.length > 1_400_000) {
      throw const FormatException('照片資料不完整');
    }
    final bytes = base64Decode(encoded);
    if (bytes.length < 4 ||
        bytes.length > 1_000_000 ||
        bytes[0] != 0xff ||
        bytes[1] != 0xd8 ||
        bytes[bytes.length - 2] != 0xff ||
        bytes[bytes.length - 1] != 0xd9) {
      throw const FormatException('照片檔案格式錯誤');
    }
    img.Image? decoded;
    try {
      decoded = img.decodeJpg(bytes);
    } catch (_) {
      throw const FormatException('照片檔案格式錯誤');
    }
    if (decoded == null ||
        decoded.width != decoded.height ||
        decoded.width > 1024) {
      throw const FormatException('照片檔案格式錯誤');
    }
    return bytes;
  }
}

const _weekdayNames = ['一', '二', '三', '四', '五', '六', '日'];

/// "今天・10月3日" / "昨天・10月2日" / "10月1日・星期四" in Taipei time.
String photoDayLabel(String day, DateTime now) {
  final d = DateTime.tryParse(day);
  if (d == null) return '日期未知';
  final wall = now.toUtc().add(const Duration(hours: 8));
  final today = DateTime(wall.year, wall.month, wall.day);
  final date = DateTime(d.year, d.month, d.day);
  final md = '${d.month}月${d.day}日';
  final diff = today.difference(date).inDays;
  if (diff == 0) return '今天・$md';
  if (diff == 1) return '昨天・$md';
  return '$md・星期${_weekdayNames[date.weekday - 1]}';
}

/// Friendly date and time in Taipei, matching the photo list's day label.
String photoClock(int ms, {DateTime? now}) =>
    friendlyTime(ms, now: now, taipei: true);

/// What the family sees when there is no photo to show, from the actual
/// consent record rather than a guess.
String photoConsentMessage(Map<String, dynamic> consent) {
  if (consent.isEmpty) return '長輩尚未開啟照片分享';
  if (consent['enabled'] == true) return '';
  if (consent['revokedAt'] is num) return '長輩已撤銷照片分享，先前的照片無法再查看';
  return '長輩已暫停照片分享';
}
