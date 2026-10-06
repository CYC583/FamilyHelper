// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';
import 'dart:convert';

import 'package:familyhelper/app/client/client_home_page.dart';
import 'package:familyhelper/app/common/firebase_service.dart';
import 'package:familyhelper/app/common/photo_loader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

class _ClientPhotoApi extends FirebaseService {
  final links = StreamController<Map<String, dynamic>>.broadcast();
  final families = StreamController<Map<String, dynamic>>.broadcast();
  final calls = <String>[];
  List<Map<String, dynamic>> photoList = const [];
  bool failListOnce = false;
  bool malformedJpeg = false;
  bool failReactOnce = false;
  final reactions = <Map<String, dynamic>>[];
  Completer<void>? getGate;

  @override
  String get uid => 'family-one';

  @override
  Stream<Map<String, dynamic>> watch(String path) => links.stream;

  @override
  Stream<Map<String, dynamic>> family(String hostId) => families.stream;

  @override
  Future<Map<String, dynamic>> call(
    String name, [
    Map<String, dynamic> data = const {},
  ]) async {
    calls.add(name);
    if (name == 'reactToPhoto') {
      if (failReactOnce) {
        failReactOnce = false;
        throw StateError('網路暫時中斷');
      }
      reactions.add(data);
      return {'ok': true};
    }
    if (name == 'listCarePhotos') {
      if (failListOnce) {
        failListOnce = false;
        throw StateError('網路暫時中斷');
      }
      return {'photos': photoList};
    }
    if (name == 'getCarePhoto') {
      if (getGate != null) await getGate!.future;
      return {
        'mediaId': data['mediaId'],
        'jpegBase64': base64Encode(
          malformedJpeg
              ? [0xff, 0xd8, 0x00, 0xff, 0xd9]
              : img.encodeJpg(img.Image(width: 8, height: 8)),
        ),
      };
    }
    return {'ok': true};
  }
}

final _photoScroll = find
    .descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    )
    .first;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(PhotoLoader.clear);

  testWidgets('家人不用滑動就能從固定四入口打開照片，原有協助仍可直接找到', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ClientPhotoApi();
    addTearDown(api.links.close);
    addTearDown(api.families.close);
    await tester.pumpWidget(MaterialApp(home: ClientHomePage(api: api)));
    api.links.add({'hostId': 'grandma'});
    await tester.pump();
    api.families.add({
      'photoConsent': {'enabled': true},
    });
    await tester.pump();

    for (final name in ['守護', '陪伴', '照片', '協助']) {
      expect(find.byKey(Key('client-tab-$name')), findsOneWidget);
    }
    await tester.tap(find.byKey(const Key('client-tab-照片')));
    await tester.pumpAndSettle();
    expect(find.text('目前還沒有照片，長輩想分享時就會出現在這裡'), findsOneWidget);
    // Remote help moved to the first tab ("長輩狀態"); the fourth is settings.
    await tester.tap(find.byKey(const Key('client-tab-守護')));
    await tester.pump();
    expect(find.text('協助操作長輩的手機（需長輩同意）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  const newest = {
    'mediaId': 'photo-new',
    'authorId': 'grandma',
    'day': '2026-10-02',
    'createdAt': 1790900000000,
  };
  const older = {
    'mediaId': 'photo-old',
    'authorId': 'grandma',
    'day': '2026-10-01',
    'createdAt': 1790800000000,
  };

  Future<_ClientPhotoApi> openPhotos(
    WidgetTester tester, {
    List<Map<String, dynamic>> photos = const [newest, older],
    Map<String, dynamic> consent = const {'enabled': true},
    void Function(_ClientPhotoApi)? setup,
    bool settle = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(360, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ClientPhotoApi()..photoList = photos;
    setup?.call(api);
    addTearDown(api.links.close);
    addTearDown(api.families.close);
    await tester.pumpWidget(MaterialApp(home: ClientHomePage(api: api)));
    api.links.add({'hostId': 'grandma'});
    await tester.pump();
    api.families.add({
      'photoConsent': consent,
      'members': {
        'family-one': {'name': '我'},
        'bro': {'name': '哥哥'},
      },
    });
    await tester.pump();
    await tester.tap(find.byKey(const Key('client-tab-照片')));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
    return api;
  }

  void mockAlbum(WidgetTester tester, Future<Object?> Function(MethodCall) h) {
    const channel = MethodChannel('familyhelper/native');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, h);
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
  }

  testWidgets('進照片頁直接看到最新一張；舊照片是縮圖，點開是獨立頁，返回仍在相簿', (tester) async {
    final api = await openPhotos(tester);
    expect(api.calls.where((c) => c == 'listCarePhotos'), hasLength(1));
    expect(find.byKey(const Key('client-photo-image')), findsOneWidget);
    expect(find.textContaining('長輩的照片・'), findsOneWidget);
    expect(find.byKey(const Key('photo-heart-photo-new')), findsOneWidget);

    final thumb = find.byKey(const Key('family-photo-photo-old'));
    await tester.scrollUntilVisible(thumb, 200, scrollable: _photoScroll);
    await tester.tap(thumb);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-viewer-image')), findsOneWidget);
    expect(find.text('上一張'), findsOneWidget);
    await tester.tap(find.byKey(const Key('photo-viewer-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-viewer-image')), findsNothing);
    expect(thumb, findsOneWidget, reason: 'album keeps its scroll position');
  });

  testWidgets('送愛心與留一句話：快速短句填入後才送出，失敗保留文字', (tester) async {
    final api = await openPhotos(tester, photos: const [newest]);
    await tester.tap(find.byKey(const Key('photo-heart-photo-new')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('reactToPhoto'));
    final heartCall = api.reactions.last;
    expect(heartCall['heart'], true);

    await tester.tap(find.byKey(const Key('photo-compose-photo-new')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('今天也想你'));
    await tester.pump();
    api.failReactOnce = true;
    await tester.ensureVisible(find.byKey(const Key('photo-send-photo-new')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-send-photo-new')));
    await tester.pumpAndSettle();
    expect(find.textContaining('沒有送出，請再按一次'), findsOneWidget);
    expect(find.text('今天也想你'), findsWidgets, reason: 'text is kept');
    await tester.tap(find.byKey(const Key('photo-send-photo-new')));
    await tester.pumpAndSettle();
    expect(api.reactions.last['comment'], '今天也想你');
  });

  testWidgets('儲存是次要操作；成功須有手機確認', (tester) async {
    final saved = <Uint8List>[];
    mockAlbum(tester, (call) async {
      if (call.method == 'savePhotoToAlbum') {
        saved.add((call.arguments as Map)['jpeg'] as Uint8List);
        return true;
      }
      return null;
    });
    await openPhotos(tester, photos: const [newest]);
    expect(saved, isEmpty);
    await tester.scrollUntilVisible(
      find.byKey(const Key('photo-save')),
      200,
      scrollable: _photoScroll,
    );
    await tester.tap(find.byKey(const Key('photo-save')));
    await tester.pumpAndSettle();
    expect(saved, hasLength(1));
    expect(saved.single.take(2).toList(), [0xff, 0xd8]);
    expect(find.text('已儲存到手機相簿'), findsOneWidget);
  });

  testWidgets('手機相簿拒絕寫入時只顯示中文失敗，不冒充已儲存', (tester) async {
    mockAlbum(tester, (call) async {
      if (call.method == 'savePhotoToAlbum') {
        throw PlatformException(code: 'PHOTO_SAVE', message: '照片未能存到手機相簿：空間不足');
      }
      return null;
    });
    await openPhotos(tester, photos: const [newest]);
    await tester.scrollUntilVisible(
      find.byKey(const Key('photo-save')),
      200,
      scrollable: _photoScroll,
    );
    await tester.tap(find.byKey(const Key('photo-save')));
    await tester.pumpAndSettle();
    expect(find.text('儲存失敗：照片未能存到手機相簿：空間不足'), findsOneWidget);
    expect(find.text('已儲存到手機相簿'), findsNothing);
  });

  testWidgets('重新整理照片失敗時不保留上一張影像冒充可查看', (tester) async {
    final api = await openPhotos(tester, photos: const [newest]);
    expect(find.byKey(const Key('client-photo-image')), findsOneWidget);
    api.failListOnce = true;
    await tester.ensureVisible(find.text('重新整理照片'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新整理照片'));
    await tester.pumpAndSettle();
    expect(find.textContaining('網路暫時中斷'), findsOneWidget);
    expect(find.byKey(const Key('client-photo-image')), findsNothing);
  });

  testWidgets('依實際同意狀態區分：尚未開啟／暫停／撤銷，且不發照片讀取請求', (tester) async {
    var api = await openPhotos(tester, consent: const {});
    expect(find.text('長輩尚未開啟照片分享'), findsOneWidget);
    expect(api.calls, isNot(contains('listCarePhotos')));
    api.families.add({
      'photoConsent': {'enabled': false, 'version': 2},
    });
    await tester.pumpAndSettle();
    expect(find.text('長輩已暫停照片分享'), findsOneWidget);
    api.families.add({
      'photoConsent': {'enabled': false, 'revokedAt': 1},
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('長輩已撤銷照片分享'), findsOneWidget);
    expect(api.calls, isNot(contains('getCarePhoto')));
  });

  testWidgets('長輩暫停分享後，即使原本的下載稍後回來也不顯示影像', (tester) async {
    final api = await openPhotos(
      tester,
      photos: const [newest],
      setup: (api) => api.getGate = Completer<void>(),
      settle: false,
    );
    await tester.pump();
    expect(api.calls, contains('getCarePhoto'));
    api.families.add({
      'photoConsent': {'enabled': false, 'version': 3},
    });
    await tester.pump();
    api.getGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('長輩已暫停照片分享'), findsOneWidget);
    expect(find.byKey(const Key('client-photo-image')), findsNothing);
    expect(find.byKey(const Key('photo-save')), findsNothing);
    expect(PhotoLoader.cached('grandma', 'photo-new'), isNull);
  });

  testWidgets('照片內容損壞但有 JPEG 標記時，顯示打不開且不提供儲存', (tester) async {
    await openPhotos(
      tester,
      photos: const [newest],
      setup: (api) => api.malformedJpeg = true,
    );
    expect(find.textContaining('照片檔案格式錯誤'), findsOneWidget);
    expect(find.textContaining('這張照片暫時打不開'), findsOneWidget);
    expect(find.byKey(const Key('photo-save')), findsNothing);
  });

  testWidgets('家人照片頁在 320dp 與兩倍文字下保留四入口且無溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ClientPhotoApi()..photoList = const [newest, older];
    addTearDown(api.links.close);
    addTearDown(api.families.close);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: ClientHomePage(api: api),
        ),
      ),
    );
    api.links.add({'hostId': 'grandma'});
    await tester.pump();
    api.families.add({
      'photoConsent': {'enabled': true},
    });
    await tester.pump();
    await tester.tap(find.byKey(const Key('client-tab-照片')));
    await tester.pumpAndSettle();
    for (final name in ['守護', '陪伴', '照片', '協助']) {
      expect(find.byKey(Key('client-tab-$name')), findsOneWidget);
    }
    await tester.scrollUntilVisible(
      find.byKey(const Key('family-photo-photo-old')),
      200,
      scrollable: _photoScroll,
    );
    expect(tester.takeException(), isNull);
  });
}
