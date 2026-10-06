// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';
import 'dart:convert';

import 'package:familyhelper/app/common/firebase_service.dart';
import 'package:familyhelper/app/common/photo_loader.dart';
import 'package:familyhelper/app/common/ui/fh_tokens.dart';
import 'package:familyhelper/app/common/ui/fh_widgets.dart';
import 'package:familyhelper/app/host/host_home_page.dart';
import 'package:familyhelper/app/host/photo_camera_service.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

class _PhotoApi extends FirebaseService {
  final families = StreamController<Map<String, dynamic>>.broadcast();
  final calls = <String>[];
  final payloads = <Map<String, dynamic>>[];
  bool failUploadOnce = false;
  bool photoServiceMissing = false;
  List<Map<String, dynamic>> photoList = const [];
  Completer<void>? uploadGate;
  Stream<Map<String, dynamic>>? watchStream;

  @override
  Stream<Map<String, dynamic>> watch(String path) =>
      watchStream ?? const Stream.empty();

  @override
  String get uid => 'grandma';

  @override
  Stream<Map<String, dynamic>> family(String hostId) => families.stream;

  @override
  Future<Map<String, dynamic>> call(
    String name, [
    Map<String, dynamic> data = const {},
  ]) async {
    calls.add(name);
    payloads.add(data);
    if (photoServiceMissing && name == 'listCarePhotos') {
      throw FirebaseFunctionsException(code: 'not-found', message: 'NOT_FOUND');
    }
    if (name == 'uploadCarePhoto' && failUploadOnce) {
      failUploadOnce = false;
      throw StateError('網路暫時中斷');
    }
    if (name == 'setPhotoConsent') return {'enabled': data['enabled']};
    if (name == 'revokePhotoConsent') return {'enabled': false};
    if (name == 'uploadCarePhoto') {
      if (uploadGate != null) await uploadGate!.future;
      return {'mediaId': 'photo-1', 'day': '2026-10-02'};
    }
    if (name == 'getCarePhoto') {
      return {
        'mediaId': data['mediaId'],
        'jpegBase64': base64Encode(
          img.encodeJpg(img.Image(width: 8, height: 8)),
        ),
      };
    }
    if (name == 'listCarePhotos') return {'photos': photoList};
    return {'ok': true};
  }
}

class _Camera implements PhotoCameraPort {
  final openedFront = <bool>[];
  int closed = 0;
  bool failCloseOnce = false;

  @override
  Future<PhotoCameraSession> open({required bool front}) async {
    openedFront.add(front);
    return _Session(this);
  }
}

class _Session implements PhotoCameraSession {
  _Session(this.camera);
  final _Camera camera;

  @override
  Widget preview({required bool mirror}) =>
      const ColoredBox(color: Colors.blue);

  @override
  Future<Uint8List> captureSquare({required bool mirror}) async =>
      Uint8List.fromList(img.encodeJpg(img.Image(width: 8, height: 8)));

  @override
  Future<void> close() async {
    camera.closed++;
    if (camera.failCloseOnce) {
      camera.failCloseOnce = false;
      throw StateError('鏡頭關閉失敗');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(PhotoLoader.clear);

  testWidgets('長輩不用滑動主畫面，就看得到固定的求助、今天、照片入口', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _PhotoApi();
    addTearDown(api.families.close);
    await tester.pumpWidget(MaterialApp(home: HostHomePage(api: api)));

    expect(find.text('呼叫家人'), findsOneWidget);
    expect(find.text('SOS\n緊急求助'), findsOneWidget);
    expect(find.byKey(const Key('host-tab-求助')), findsOneWidget);
    expect(find.byKey(const Key('host-tab-今天')), findsOneWidget);
    expect(find.byKey(const Key('host-tab-照片')), findsOneWidget);
    await tester.tap(find.byKey(const Key('host-tab-照片')));
    await tester.pump();
    expect(find.text('拍一張給家人'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('照片頁的大按鈕直接開啟 App 內的 1:1 自拍畫面', (tester) async {
    final api = _PhotoApi();
    final camera = _Camera();
    addTearDown(api.families.close);
    await tester.pumpWidget(
      MaterialApp(
        home: HostHomePage(api: api, photoCameraPort: camera),
      ),
    );
    await tester.tap(find.byKey(const Key('host-tab-照片')));
    await tester.pump();
    final cameraButton = find.byKey(const Key('host-open-camera'));
    expect(cameraButton, findsOneWidget);
    await tester.tap(cameraButton);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('host-square-camera')), findsOneWidget);
    expect(find.text('現在：拍自己'), findsOneWidget);
    expect(camera.openedFront, [true]);
  });

  testWidgets('翻轉、拍照、確認分享才會送出，成功後返回照片頁', (tester) async {
    final api = _PhotoApi();
    final camera = _Camera();
    addTearDown(api.families.close);
    await tester.pumpWidget(
      MaterialApp(
        home: HostHomePage(api: api, photoCameraPort: camera),
      ),
    );
    await tester.tap(find.byKey(const Key('host-tab-照片')));
    await tester.pump();
    await tester.tap(find.text('拍一張給家人'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('拍前面'));
    await tester.pumpAndSettle();
    expect(camera.openedFront, [true, false]);
    await tester.tap(find.text('拍照'));
    await tester.pumpAndSettle();
    expect(api.calls.contains('uploadCarePhoto'), false);
    await tester.tap(find.text('分享給家人'));
    await tester.pumpAndSettle();
    expect(find.text('同意分享照片？'), findsOneWidget);
    expect(find.textContaining('先前暫停分享的照片'), findsOneWidget);
    expect(api.calls.contains('uploadCarePhoto'), false);
    await tester.tap(find.text('同意並分享'));
    await tester.pumpAndSettle();
    expect(
      api.calls,
      containsAllInOrder(['setPhotoConsent', 'uploadCarePhoto']),
    );
    expect(
      api.payloads[api.calls.indexOf('uploadCarePhoto')]['jpegBase64'],
      isNotEmpty,
    );
    expect(find.text('拍一張給家人'), findsOneWidget);
    final success = find.byKey(const Key('host-photo-status'));
    expect(success, findsOneWidget);
    expect(tester.widget<FhStatusBanner>(success).tone, FhTone.success);
  });

  testWidgets('上傳失敗不顯示成功，同一張照片重試沿用相同操作碼', (tester) async {
    final api = _PhotoApi()..failUploadOnce = true;
    addTearDown(api.families.close);
    await tester.pumpWidget(
      MaterialApp(
        home: HostHomePage(api: api, photoCameraPort: _Camera()),
      ),
    );
    await tester.tap(find.byKey(const Key('host-tab-照片')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('host-open-camera')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('拍照'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分享給家人'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('同意並分享'));
    await tester.pumpAndSettle();
    expect(find.textContaining('照片尚未分享，照片還在'), findsOneWidget);
    expect(find.text('這張要給家人看嗎？'), findsOneWidget);
    expect(find.text('照片已分享，家人可以看了'), findsNothing);
    await tester.tap(find.text('再試一次'));
    await tester.pumpAndSettle();
    final uploads = <Map<String, dynamic>>[];
    for (var i = 0; i < api.calls.length; i++) {
      if (api.calls[i] == 'uploadCarePhoto') uploads.add(api.payloads[i]);
    }
    expect(uploads.length, 2);
    expect(uploads[0]['opId'], uploads[1]['opId']);
    expect(find.text('拍一張給家人'), findsOneWidget);
  });

  testWidgets('320dp 與 200% 大字仍看得見自拍、重拍與分享，不爆版', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _PhotoApi();
    addTearDown(api.families.close);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: HostHomePage(api: api, photoCameraPort: _Camera()),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('host-tab-照片')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('host-open-camera')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('host-square-camera')), findsOneWidget);
    expect(find.text('拍照'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('拍照'));
    await tester.pumpAndSettle();
    expect(find.text('重拍'), findsOneWidget);
    expect(find.text('分享給家人'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('分享給家人'));
    await tester.pumpAndSettle();
    expect(find.text('同意分享照片？'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('320dp／200% 大字首頁兩個求助主按鈕無須滑動', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _PhotoApi();
    addTearDown(api.families.close);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: HostHomePage(api: api),
        ),
      ),
    );
    final sos = find.text('SOS\n緊急求助');
    final nav = find.byKey(const Key('host-tab-求助'));
    expect(sos, findsOneWidget);
    expect(tester.getBottomRight(sos).dy, lessThan(tester.getTopLeft(nav).dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('320×568、200% 字體的兩個求助主按鈕仍完整可見', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _PhotoApi();
    addTearDown(api.families.close);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: HostHomePage(api: api),
        ),
      ),
    );
    final nav = find.byKey(const Key('host-tab-求助'));
    for (final label in ['呼叫家人', 'SOS\n緊急求助']) {
      final rect = tester.getRect(find.text(label));
      expect(rect.top, greaterThan(0));
      expect(rect.bottom, lessThan(tester.getTopLeft(nav).dy));
      final button = tester.getRect(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(FilledButton),
        ),
      );
      expect(button.height, greaterThanOrEqualTo(120));
      expect(button.bottom, lessThanOrEqualTo(tester.getTopLeft(nav).dy));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('高螢幕兩個主按鈕延展至導覽列附近，不留無用大空白', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _PhotoApi();
    addTearDown(api.families.close);
    await tester.pumpWidget(MaterialApp(home: HostHomePage(api: api)));
    final sos = find.text('SOS\n緊急求助');
    final nav = find.byKey(const Key('host-tab-求助'));
    final gap = tester.getTopLeft(nav).dy - tester.getBottomRight(sos).dy;
    expect(gap, lessThan(110));
    expect(tester.takeException(), isNull);
  });

  testWidgets('640×360 短橫向兩個主按鈕並排且不用滑動', (tester) async {
    await tester.binding.setSurfaceSize(const Size(640, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _PhotoApi();
    addTearDown(api.families.close);
    await tester.pumpWidget(MaterialApp(home: HostHomePage(api: api)));
    final call = find.text('呼叫家人');
    final sos = find.text('SOS\n緊急求助');
    final nav = find.byKey(const Key('host-tab-求助'));
    expect(tester.getTopLeft(call).dx, lessThan(tester.getTopLeft(sos).dx));
    expect(tester.getBottomRight(sos).dy, lessThan(tester.getTopLeft(nav).dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('照片後端未開通時明確中文提示，不冒充今日照片', (tester) async {
    final api = _PhotoApi()..photoServiceMissing = true;
    addTearDown(api.families.close);
    await tester.pumpWidget(MaterialApp(home: HostHomePage(api: api)));
    await tester.tap(find.byKey(const Key('host-tab-照片')));
    await tester.pumpAndSettle();
    expect(find.textContaining('照片服務尚未開通'), findsOneWidget);
    expect(find.byKey(const Key('host-today-photo')), findsNothing);
    expect(find.text('再試一次'), findsOneWidget);
  });

  testWidgets('長輩可從照片頁明確撤銷先前照片的家人讀取權', (tester) async {
    final api = _PhotoApi();
    addTearDown(api.families.close);
    await tester.pumpWidget(MaterialApp(home: HostHomePage(api: api)));
    await tester.tap(find.byKey(const Key('host-tab-照片')));
    await tester.pump();
    api.families.add({
      'photoConsent': {'enabled': true},
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('host-photo-manage')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-revoke')));
    await tester.pumpAndSettle();
    expect(find.text('撤銷照片分享？'), findsOneWidget);
    expect(api.calls.contains('revokePhotoConsent'), false);
    await tester.tap(find.text('確認撤銷'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('revokePhotoConsent'));
    expect(find.textContaining('家人不能再看先前照片'), findsOneWidget);
  });

  testWidgets('長輩按暫停後必須收到伺服器確認，並隱藏舊照片狀態', (tester) async {
    final api = _PhotoApi();
    addTearDown(api.families.close);
    await tester.pumpWidget(MaterialApp(home: HostHomePage(api: api)));
    await tester.tap(find.byKey(const Key('host-tab-照片')));
    await tester.pump();
    api.families.add({
      'photoConsent': {'enabled': true},
    });
    await tester.pumpAndSettle();
    expect(find.text('分享中・管理'), findsOneWidget);
    await tester.tap(find.byKey(const Key('host-photo-manage')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-pause')));
    await tester.pumpAndSettle();
    final i = api.calls.indexOf('setPhotoConsent');
    expect(i, greaterThanOrEqualTo(0));
    expect(api.payloads[i]['enabled'], false);
    expect(find.textContaining('家人目前無法查看照片'), findsOneWidget);
  });

  testWidgets('昨天照片列在「最近分享」，不冒充今日照片，仍可拍今天的', (tester) async {
    final taipeiNow = DateTime.now().toUtc().add(const Duration(hours: 8));
    final yesterday = DateTime.utc(
      taipeiNow.year,
      taipeiNow.month,
      taipeiNow.day,
    ).subtract(const Duration(days: 1)).toIso8601String().substring(0, 10);
    final api = _PhotoApi()
      ..photoList = [
        {'mediaId': 'yesterday-photo', 'day': yesterday},
      ];
    addTearDown(api.families.close);
    await tester.pumpWidget(MaterialApp(home: HostHomePage(api: api)));
    await tester.tap(find.byKey(const Key('host-tab-照片')));
    await tester.pumpAndSettle();
    expect(find.text('今天想分享什麼？'), findsOneWidget);
    expect(find.byKey(const Key('host-open-camera')), findsOneWidget);
    expect(find.byKey(const Key('host-today-photo')), findsNothing);
    expect(find.textContaining('昨天・'), findsOneWidget);
  });

  testWidgets('今天照片可從私有 callable 讀回並顯示', (tester) async {
    final taipeiNow = DateTime.now().toUtc().add(const Duration(hours: 8));
    final today = DateTime.utc(
      taipeiNow.year,
      taipeiNow.month,
      taipeiNow.day,
    ).toIso8601String().substring(0, 10);
    final api = _PhotoApi()
      ..photoList = [
        {'mediaId': 'today-photo', 'day': today},
      ];
    addTearDown(api.families.close);
    await tester.pumpWidget(MaterialApp(home: HostHomePage(api: api)));
    await tester.tap(find.byKey(const Key('host-tab-照片')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('getCarePhoto'));
    expect(find.byKey(const Key('host-today-photo')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('今天已分享給家人 ✓'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('host-open-camera')), findsNothing);
  });

  testWidgets('切換鏡頭時舊鏡頭關閉失敗，顯示錯誤而不會卡在載入中', (tester) async {
    final api = _PhotoApi();
    final camera = _Camera();
    addTearDown(api.families.close);
    await tester.pumpWidget(
      MaterialApp(
        home: HostHomePage(api: api, photoCameraPort: camera),
      ),
    );
    await tester.tap(find.byKey(const Key('host-tab-照片')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('host-open-camera')));
    await tester.pumpAndSettle();
    camera.failCloseOnce = true;
    await tester.tap(find.text('拍前面'));
    await tester.pumpAndSettle();
    expect(find.textContaining('鏡頭關閉失敗'), findsWidgets);
    expect(find.text('重新開啟相機'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('分享等待伺服器時顯示進度、停用重複點按', (tester) async {
    final api = _PhotoApi()..uploadGate = Completer<void>();
    addTearDown(api.families.close);
    await tester.pumpWidget(
      MaterialApp(
        home: HostHomePage(api: api, photoCameraPort: _Camera()),
      ),
    );
    await tester.tap(find.byKey(const Key('host-tab-照片')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('host-open-camera')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('拍照'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分享給家人'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('同意並分享'));
    await tester.pump();
    expect(find.text('正在分享，請稍等'), findsOneWidget);
    final shareButton = find.widgetWithText(FilledButton, '分享給家人');
    expect(tester.widget<FilledButton>(shareButton).onPressed, isNull);
    api.uploadGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('照片已分享，家人可以看了'), findsWidgets);
    expect(find.byType(SnackBar), findsNothing);
  });

  String taipeiDay(int back) {
    final now = DateTime.now().toUtc().add(const Duration(hours: 8));
    return DateTime.utc(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: back)).toIso8601String().substring(0, 10);
  }

  testWidgets('看看以前的照片：大縮圖列表，點開全螢幕，有返回與上一張／下一張', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _PhotoApi()
      ..photoList = [
        {'mediaId': 'p0', 'day': taipeiDay(0), 'createdAt': 3},
        {'mediaId': 'p1', 'day': taipeiDay(1), 'createdAt': 2},
        {'mediaId': 'p2', 'day': taipeiDay(2), 'createdAt': 1},
      ];
    addTearDown(api.families.close);
    await tester.pumpWidget(MaterialApp(home: HostHomePage(api: api)));
    await tester.tap(find.byKey(const Key('host-tab-照片')));
    await tester.pumpAndSettle();
    final history = find.byKey(const Key('host-photo-history'));
    await tester.scrollUntilVisible(
      history,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -120));
    await tester.pumpAndSettle();
    await tester.tap(history);
    await tester.pumpAndSettle();
    expect(find.text('以前的照片'), findsOneWidget);
    expect(find.textContaining('昨天・'), findsOneWidget);
    await tester.tap(find.byKey(const Key('host-history-p1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-viewer-image')), findsOneWidget);
    await tester.tap(find.byKey(const Key('photo-viewer-older')));
    await tester.pumpAndSettle();
    expect(api.payloads.last['mediaId'], 'p2');
    await tester.tap(find.byKey(const Key('photo-viewer-back')));
    await tester.pumpAndSettle();
    expect(find.text('以前的照片'), findsOneWidget);
  });

  testWidgets('暫停後可從「管理」恢復分享，不必再拍一張', (tester) async {
    final api = _PhotoApi();
    addTearDown(api.families.close);
    await tester.pumpWidget(MaterialApp(home: HostHomePage(api: api)));
    await tester.tap(find.byKey(const Key('host-tab-照片')));
    await tester.pump();
    api.families.add({
      'photoConsent': {'enabled': false, 'version': 2},
    });
    await tester.pumpAndSettle();
    expect(find.text('未分享・管理'), findsOneWidget);
    await tester.tap(find.byKey(const Key('host-photo-manage')));
    await tester.pumpAndSettle();
    expect(find.text('現在：已暫停，家人看不到照片'), findsOneWidget);
    await tester.tap(find.byKey(const Key('photo-resume')));
    await tester.pumpAndSettle();
    expect(find.textContaining('還沒到期'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '恢復分享'));
    await tester.pumpAndSettle();
    final i = api.calls.lastIndexOf('setPhotoConsent');
    expect(api.payloads[i]['enabled'], true);
    expect(find.text('已恢復分享，家人可以看照片了'), findsOneWidget);
  });

  testWidgets('今天照片下方顯示誰送愛心與留言，可按「聽家人的留言」', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final spoken = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('familyhelper/native'),
      (call) async {
        if (call.method == 'speakText') {
          spoken.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('familyhelper/native'),
        null,
      ),
    );
    final reactions = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(reactions.close);
    final api = _PhotoApi()
      ..photoList = [
        {'mediaId': 'p0', 'day': taipeiDay(0), 'createdAt': 3},
      ]
      ..watchStream = reactions.stream;
    addTearDown(api.families.close);
    await tester.pumpWidget(MaterialApp(home: HostHomePage(api: api)));
    await tester.tap(find.byKey(const Key('host-tab-照片')));
    await tester.pumpAndSettle();
    api.families.add({
      'photoConsent': {'enabled': true},
      'members': {
        'bro': {'name': '哥哥'},
        'sis': {'name': '小美'},
      },
    });
    reactions.add({
      'bro': {'heart': true, 'comment': '長輩今天氣色很好！'},
      'sis': {'heart': true},
    });
    await tester.pumpAndSettle();
    final listen = find.byKey(const Key('photo-listen-p0'));
    await tester.ensureVisible(listen);
    await tester.pumpAndSettle();
    expect(find.text('哥哥、小美送來了愛心 ♥'), findsOneWidget);
    expect(find.text('哥哥：長輩今天氣色很好！'), findsOneWidget);
    await tester.tap(listen);
    await tester.pump();
    expect(spoken.single, contains('哥哥說：長輩今天氣色很好！'));
  });

  for (final width in [320.0, 360.0, 412.0]) {
    testWidgets('${width.toInt()}dp／200% 字：今天照片頁與全螢幕照片不爆版', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _PhotoApi()
        ..photoList = [
          {'mediaId': 'p0', 'day': taipeiDay(0), 'createdAt': 3},
          {'mediaId': 'p1', 'day': taipeiDay(1), 'createdAt': 2},
        ];
      addTearDown(api.families.close);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 640),
              textScaler: const TextScaler.linear(2),
            ),
            child: HostHomePage(api: api),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('host-tab-照片')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('host-today-photo')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('photo-viewer-back')), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('photo-viewer-older')),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
