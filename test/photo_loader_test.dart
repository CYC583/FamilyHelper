// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:convert';

import 'package:familyhelper/app/common/firebase_service.dart';
import 'package:familyhelper/app/common/photo_loader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

class _Api extends FirebaseService {
  final calls = <String>[];
  @override
  Future<Map<String, dynamic>> call(
    String name, [
    Map<String, dynamic> data = const {},
  ]) async {
    calls.add('${data['mediaId']}');
    return {
      'mediaId': data['mediaId'],
      'jpegBase64': base64Encode(img.encodeJpg(img.Image(width: 8, height: 8))),
    };
  }
}

void main() {
  setUp(PhotoLoader.clear);

  test('loads, validates, caches; at most two downloads at once', () async {
    final api = _Api();
    final all = await Future.wait([
      for (final id in ['a', 'b', 'c', 'a']) PhotoLoader.load(api, 'g', id),
    ]);
    expect(all, hasLength(4));
    expect(api.calls, ['a', 'b', 'c'], reason: 'same photo is fetched once');
    expect(PhotoLoader.cached('g', 'c'), isNotNull);
    await PhotoLoader.load(api, 'g', 'b');
    expect(api.calls, hasLength(3), reason: 'served from cache');
    PhotoLoader.clear();
    expect(PhotoLoader.cached('g', 'b'), isNull);
  });

  test('day labels use Taipei date', () {
    final now = DateTime.utc(2026, 10, 3, 2);
    expect(photoDayLabel('2026-10-03', now), '今天・10月3日');
    expect(photoDayLabel('2026-10-02', now), '昨天・10月2日');
    expect(photoDayLabel('2026-10-01', now), '10月1日・星期四');
    expect(photoConsentMessage({}), '長輩尚未開啟照片分享');
    expect(photoConsentMessage({'enabled': false}), '長輩已暫停照片分享');
    expect(
      photoConsentMessage({'enabled': false, 'revokedAt': 1}),
      contains('撤銷'),
    );
  });
}
