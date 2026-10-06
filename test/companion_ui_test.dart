// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:familyhelper/app/client/client_companion_page.dart';
import 'package:familyhelper/app/client/incoming_alert_page.dart';
import 'package:familyhelper/app/client/client_place_panel.dart';
import 'package:familyhelper/app/client/handling_bar.dart';
import 'package:familyhelper/app/common/family_messages_panel.dart';
import 'package:familyhelper/app/common/firebase_service.dart';
import 'package:familyhelper/app/common/photo_reactions.dart';
import 'package:familyhelper/app/host/host_care_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Api extends FirebaseService {
  _Api(this.me);
  final String me;
  final streams = <String, StreamController<Map<String, dynamic>>>{};
  final reads = <String, Map<String, dynamic>>{};
  final calls = <(String, Map<String, dynamic>)>[];
  Object? failWith;

  StreamController<Map<String, dynamic>> at(String path) => streams.putIfAbsent(
    path,
    StreamController<Map<String, dynamic>>.broadcast,
  );

  @override
  String get uid => me;
  @override
  Stream<Map<String, dynamic>> watch(String path) => at(path).stream;
  @override
  Future<Map<String, dynamic>> read(String path) async => reads[path] ?? {};
  @override
  Future<Map<String, dynamic>> call(
    String name, [
    Map<String, dynamic> data = const {},
  ]) async {
    calls.add((name, data));
    if (failWith != null) throw failWith!;
    if (name == 'getVoiceMessage') return {'audioBase64': 'AAAA'};
    if (name == 'listCarePhotos') return {'photos': []};
    return {'ok': true};
  }

  void close() {
    for (final s in streams.values) {
      s.close();
    }
  }
}

class _Voice implements VoicePort {
  bool granted = true;
  final log = <String>[];
  @override
  Future<bool> ensurePermission() async => granted;
  @override
  Future<void> start() async => log.add('start');
  @override
  Future<Map<String, dynamic>> stop() async {
    log.add('stop');
    return {'audioBase64': 'AAAA', 'durationMs': 4000};
  }

  @override
  Future<void> cancel() async => log.add('cancel');
  @override
  Future<void> play(String audioBase64) async => log.add('play:$audioBase64');
  @override
  Future<void> stopPlay() async => log.add('stopPlay');
  @override
  Future<double> level() async => 0.5;
}

final _now = DateTime.utc(2026, 10, 2, 4); // Fri 12:00 Taipei

Widget _app(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets('family text is shown as sent only after the server accepts it', (
    tester,
  ) async {
    final api = _Api('alice');
    addTearDown(api.close);
    await tester.pumpWidget(
      _app(
        FamilyMessagesPanel(
          api: api,
          hostId: 'grandma',
          selfUid: 'alice',
          isHost: false,
          names: const {'alice': 'A', 'bob': 'B'},
          voice: _Voice(),
          clock: () => _now,
        ),
      ),
    );
    api.at('care/grandma/messages/items').add({
      'm1': {
        'authorId': 'bob',
        'kind': 'text',
        'text': '長輩早安',
        'createdAt': _now.millisecondsSinceEpoch - 1000,
        'expiresAt': _now.millisecondsSinceEpoch + 1000000,
      },
      'gone': {
        'authorId': 'removed-member',
        'kind': 'text',
        'text': '已解除者的留言',
        'createdAt': 1,
        'expiresAt': _now.millisecondsSinceEpoch + 1000000,
      },
      'pending': {
        'authorId': 'bob',
        'kind': 'voice',
        'status': 'pending',
        'createdAt': 2,
        'expiresAt': _now.millisecondsSinceEpoch + 1000000,
      },
    });
    await tester.pump();
    expect(find.text('長輩早安'), findsOneWidget);
    expect(find.text('已解除者的留言'), findsNothing);
    expect(find.byKey(const Key('message-pending')), findsNothing);

    api.failWith = StateError('網路中斷');
    await tester.enterText(find.byKey(const Key('message-input')), '我晚點打給你');
    await tester.tap(find.byKey(const Key('message-send')));
    await tester.pump();
    expect(find.textContaining('沒有送出'), findsOneWidget);
    expect(find.text('已送出'), findsNothing);

    api.failWith = null;
    await tester.tap(find.byKey(const Key('message-send')));
    await tester.pump();
    expect(find.text('已送出'), findsOneWidget);
    expect(api.calls.last.$2['text'], '我晚點打給你');
  });

  testWidgets('hold to talk shows a live waveform and sends on release', (
    tester,
  ) async {
    final api = _Api('alice');
    final voice = _Voice()..granted = false;
    addTearDown(api.close);
    await tester.pumpWidget(
      _app(
        FamilyMessagesPanel(
          api: api,
          hostId: 'grandma',
          selfUid: 'alice',
          isHost: true,
          voice: voice,
          clock: () => _now,
        ),
      ),
    );
    expect(find.byType(TextField), findsNothing, reason: 'grandma never types');
    final button = find.byKey(const Key('voice-record'));
    var gesture = await tester.startGesture(tester.getCenter(button));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.up();
    await tester.pump();
    expect(find.textContaining('需要允許使用麥克風'), findsOneWidget);
    expect(voice.log, isEmpty);

    voice.granted = true;
    gesture = await tester.startGesture(tester.getCenter(button));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('voice-waveform')), findsOneWidget);
    expect(find.textContaining('放開就送出'), findsOneWidget);
    await gesture.up();
    await tester.pump();
    await tester.pump();
    expect(voice.log, ['start', 'stop']);
    final sent = api.calls.single;
    expect(sent.$1, 'sendCareMessage');
    expect(sent.$2['kind'], 'voice');
    expect(sent.$2['durationMs'], 4000);

    api.at('care/grandma/messages/items').add({
      'v1': {
        'authorId': 'alice',
        'kind': 'voice',
        'status': 'ready',
        'durationMs': 6000,
        'createdAt': 5,
        'expiresAt': _now.millisecondsSinceEpoch + 1000000,
      },
    });
    await tester.pump();
    await tester.tap(find.textContaining('聽語音'));
    await tester.pump();
    expect(voice.log.last, 'play:AAAA');
  });

  testWidgets('family sees today reminder status reported by grandma phone', (
    tester,
  ) async {
    final api = _Api('alice');
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ClientCompanionPage(
            api: api,
            hostId: 'grandma',
            family: const {},
            clock: () => _now,
            voice: _Voice(),
          ),
        ),
      ),
    );
    api.at('care/grandma/settings/reminderPlan').add({
      'version': 3,
      'items': [
        {'id': 'r-1', 'type': 'medicine', 'time': '08:00', 'text': '早藥'},
        {'id': 'r-2', 'type': 'water', 'time': '15:00', 'text': ''},
      ],
    });
    api.at('care/grandma/reminderStatus/sync').add({'version': 2});
    await tester.pump();
    expect(find.text('長輩手機尚未同步這次修改'), findsNWidgets(2));
    api.at('care/grandma/reminderStatus/sync').add({'version': 3});
    api.at('care/grandma/reminderStatus/days/2026-10-02').add({
      'r-1': {'state': 'played', 'at': _now.millisecondsSinceEpoch - 60000},
    });
    await tester.pump();
    expect(find.textContaining('手機回報已播放'), findsOneWidget);
    expect(find.text('等待播放'), findsOneWidget);
  });

  testWidgets('photo heart is sent and counted from the stream', (
    tester,
  ) async {
    final api = _Api('alice');
    addTearDown(api.close);
    await tester.pumpWidget(
      _app(PhotoReactions(api: api, hostId: 'grandma', mediaId: 'm1')),
    );
    api.at('care/grandma/photoReactions/m1').add({
      'bob': {'heart': true, 'comment': '好看'},
    });
    await tester.pump();
    expect(find.text('家人送來了愛心 ♥'), findsOneWidget);
    expect(find.text('家人：好看'), findsOneWidget);
    await tester.tap(find.byKey(const Key('photo-heart-m1')));
    await tester.pump();
    expect(api.calls.single.$1, 'reactToPhoto');
    expect(api.calls.single.$2['heart'], true);
  });

  group('host Today companion panel', () {
    final native = <MethodCall>[];
    setUp(() {
      native.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('familyhelper/native'),
            (call) async {
              native.add(call);
              if (call.method == 'careSnapshot') {
                return {
                  'enabled': true,
                  'plan': [
                    {
                      'id': 'r-1',
                      'type': 'medicine',
                      'time': '08:00',
                      'text': '早上那顆',
                      'author': '小明',
                    },
                    {'type': 'water', 'time': '15:00', 'text': ''},
                  ],
                  'disclosure': 2,
                  'deliveries': {'2026-10-02:r-1': 'played'},
                  'responses': <String, String>{},
                  'companionVersion': 0,
                  'companionItems': {'responses': false},
                };
              }
              return true;
            },
          );
    });
    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('familyhelper/native'),
            null,
          ),
    );

    testWidgets('reminders are listed for grandma with no buttons to press', (
      tester,
    ) async {
      final api = _Api('grandma');
      addTearDown(api.close);
      await tester.pumpWidget(_app(HostCarePanel(api: api, clock: () => _now)));
      await tester.pumpAndSettle();
      expect(find.textContaining('已播放'), findsOneWidget);
      expect(find.textContaining('等等會提醒你'), findsOneWidget);
      expect(find.byKey(const Key('replay-2026-10-02:r-1')), findsOneWidget);
      expect(find.text('吃了'), findsNothing);
      expect(find.text('稍後'), findsNothing);
      expect(find.textContaining('小明・'), findsOneWidget);
      expect(native.any((c) => c.method == 'careSaveQuotes'), isTrue);
    });

    for (final size in const [Size(320, 568), Size(360, 640)]) {
      testWidgets('panel fits ${size.width.toInt()}dp at 200% text', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final api = _Api('grandma');
        addTearDown(api.close);
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: const TextScaler.linear(2),
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: HostCarePanel(api: api, clock: () => _now),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('早上那顆'), findsOneWidget);
      });
    }
  });

  testWidgets('SOS pops a red full-screen alert, reads it aloud and answers', (
    tester,
  ) async {
    final api = _Api('alice');
    final spoken = <String>[];
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: IncomingAlertPage(
          api: api,
          hostId: 'grandma',
          alertId: 'a1',
          alert: const {'type': 'sos', 'sessionId': 's1', 'createdAt': 1},
          speak: (text) async => spoken.add(text),
        ),
      ),
    );
    expect(find.text('長輩按了緊急求助'), findsOneWidget);
    expect(spoken.single, contains('緊急'));
    await tester.tap(find.byKey(const Key('incoming-answer')));
    await tester.pump();
    expect(api.calls.first.$1, 'answerHostCall');
    expect(api.calls.first.$2['sessionId'], 's1');
  });

  testWidgets(
    'when another family member answers, the ringing screen says who',
    (tester) async {
      final api = _Api('alice');
      final spoken = <String>[];
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: IncomingAlertPage(
            api: api,
            hostId: 'grandma',
            alertId: 'a2',
            alert: const {'type': 'call', 'sessionId': 's2', 'createdAt': 1},
            speak: (text) async => spoken.add(text),
          ),
        ),
      );
      expect(find.byKey(const Key('incoming-answer')), findsOneWidget);
      api.at('core/families/grandma/alerts/a2').add({
        'type': 'call',
        'answeredBy': {'uid': 'bob', 'name': '哥哥', 'at': 2},
      });
      await tester.pump();
      expect(find.text('哥哥 已搶先接聽'), findsOneWidget);
      expect(find.byKey(const Key('incoming-answer')), findsNothing);
      expect(spoken.last, contains('哥哥'));
      await tester.pump(const Duration(seconds: 6));
    },
  );

  testWidgets(
    'with many messages the talk button stays pinned and newest shows',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final api = _Api('grandma');
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FamilyMessagesPanel(
              api: api,
              hostId: 'grandma',
              selfUid: 'grandma',
              isHost: true,
              voice: _Voice(),
              clock: () => _now,
              fillHeight: true,
            ),
          ),
        ),
      );
      api.at('care/grandma/messages/items').add({
        for (var i = 0; i < 25; i++)
          'm$i': {
            'authorId': 'grandma',
            'kind': 'text',
            'text': '第$i則',
            'createdAt': 1000 + i,
            'expiresAt': _now.millisecondsSinceEpoch + 1000000,
          },
      });
      await tester.pump();
      final button = tester.getRect(find.byKey(const Key('voice-record')));
      expect(button.bottom, lessThanOrEqualTo(640));
      expect(button.top, greaterThan(400), reason: 'pinned near the bottom');
      expect(find.text('第24則'), findsOneWidget, reason: 'newest visible first');
      expect(find.text('第0則'), findsNothing);
    },
  );

  testWidgets(
    'family sees only the latest place event, with late arrival noted',
    (tester) async {
      final api = _Api('alice');
      addTearDown(api.close);
      await tester.pumpWidget(
        _app(ClientPlacePanel(api: api, hostId: 'grandma')),
      );
      api.at('care/grandma/places/consent').add({
        'enabled': true,
        'status': 'enabled',
        'disclosureVersion': 1,
        'workName': '活動中心',
      });
      await tester.pump();
      final eight = DateTime.utc(2026, 10, 3, 0, 12).millisecondsSinceEpoch;
      api.at('care/grandma/places/events').add({
        'e1': {
          'place': 'home',
          'transition': 'exit',
          'at': eight,
          'receivedAt': eight + 20 * 60000,
        },
        'e2': {
          'place': 'work',
          'transition': 'enter',
          'at': eight - 3600000,
          'receivedAt': eight - 3600000,
        },
      });
      await tester.pump();
      await tester.pump();
      final latest = tester
          .widget<Text>(find.byKey(const Key('place-latest')))
          .data!;
      expect(latest, contains('08:12 離開家'));
      expect(latest, contains('08:32 才收到'));
      expect(
        find.textContaining('活動中心'),
        findsNothing,
        reason: 'older rows hidden until expanded',
      );
      await tester.tap(find.text('查看紀錄'));
      await tester.pump();
      expect(find.textContaining('到活動中心'), findsOneWidget);
      expect(find.textContaining('目前在家'), findsNothing);
    },
  );

  testWidgets(
    'tap mode: start, stop, preview, failed send keeps the recording',
    (tester) async {
      final api = _Api('grandma');
      final voice = _Voice();
      addTearDown(api.close);
      await tester.pumpWidget(
        _app(
          FamilyMessagesPanel(
            api: api,
            hostId: 'grandma',
            selfUid: 'grandma',
            isHost: true,
            voice: voice,
            clock: () => _now,
            tapMode: true,
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('voice-tap-start')));
      await tester.pump();
      expect(find.byKey(const Key('voice-waveform')), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-tap-stop')));
      await tester.pumpAndSettle();
      expect(
        api.calls,
        isEmpty,
        reason: 'nothing is sent before the person chooses',
      );
      await tester.tap(find.byKey(const Key('voice-preview')));
      await tester.pump();
      expect(voice.log.last, 'play:AAAA');
      api.failWith = StateError('offline');
      await tester.tap(find.byKey(const Key('voice-send')));
      await tester.pumpAndSettle();
      expect(find.text('再傳一次'), findsOneWidget);
      api.failWith = null;
      await tester.tap(find.byKey(const Key('voice-send')));
      await tester.pumpAndSettle();
      expect(api.calls.where((c) => c.$1 == 'sendCareMessage'), hasLength(2));
      expect(find.byKey(const Key('voice-tap-start')), findsOneWidget);
    },
  );

  testWidgets(
    'handling: someone else claimed it, I see who and cannot take over',
    (tester) async {
      final api = _Api('alice');
      addTearDown(api.close);
      await tester.pumpWidget(
        _app(HandlingBar(api: api, hostId: 'grandma', eventKey: 'battery-e1')),
      );
      expect(find.text('還沒有人接手'), findsOneWidget);
      api.at('care/grandma/handling/battery-e1').add({
        'status': 'claimed',
        'by': 'bro',
        'name': '哥哥',
        'at': 1,
      });
      await tester.pump();
      expect(find.text('哥哥 已接手處理'), findsOneWidget);
      final claim = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '我來處理'),
      );
      expect(claim.onPressed, isNull);
      api.at('care/grandma/handling/battery-e1').add({
        'status': 'resolved',
        'by': 'bro',
        'name': '哥哥',
        'note': '已提醒充電',
        'at': 2,
      });
      await tester.pump();
      expect(find.text('已處理：已提醒充電（哥哥）'), findsOneWidget);
    },
  );
}
