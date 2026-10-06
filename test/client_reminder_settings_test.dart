// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:familyhelper/app/client/client_reminder_settings_page.dart';
import 'package:familyhelper/app/client/client_voice_profile_page.dart';
import 'package:familyhelper/app/common/family_messages_panel.dart';
import 'package:familyhelper/app/common/firebase_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Api extends FirebaseService {
  final streams = <String, StreamController<Map<String, dynamic>>>{};
  final calls = <(String, Map<String, dynamic>)>[];
  Object? failSave;
  void Function()? onFail;

  StreamController<Map<String, dynamic>> at(String path) => streams.putIfAbsent(
    path,
    StreamController<Map<String, dynamic>>.broadcast,
  );

  @override
  Stream<Map<String, dynamic>> watch(String path) => at(path).stream;

  @override
  Future<Map<String, dynamic>> call(
    String name, [
    Map<String, dynamic> data = const {},
  ]) async {
    calls.add((name, data));
    if (name == 'setReminderPlan' && failSave != null) {
      final f = failSave!;
      if (onFail != null) {
        failSave = null;
        onFail!();
      }
      throw f;
    }
    if (name == 'uploadReminderVoice') {
      return {'voiceId': 'v-1', 'durationMs': 4000};
    }
    if (name == 'getReminderVoice') return {'audioBase64': 'AAAA'};
    return {'version': 1};
  }

  void close() {
    for (final s in streams.values) {
      s.close();
    }
  }
}

class _MeApi extends _Api {
  @override
  String get uid => 'me';
}

class _Voice implements VoicePort {
  final log = <String>[];
  @override
  Future<bool> ensurePermission() async => true;
  @override
  Future<void> start() async => log.add('start');
  @override
  Future<Map<String, dynamic>> stop() async {
    log.add('stop');
    return {'audioBase64': 'AAAA', 'durationMs': 4000};
  }

  @override
  Future<void> cancel() async {}
  @override
  Future<void> play(String audioBase64) async => log.add('play');
  @override
  Future<void> stopPlay() async {}
  @override
  Future<double> level() async => 0.3;
}

const _plan = 'care/grandma/settings/reminderPlan';

Future<_Api> _open(WidgetTester tester, {_Voice? voice}) async {
  final api = _Api();
  addTearDown(api.close);
  await tester.pumpWidget(
    MaterialApp(
      home: ClientReminderSettingsPage(
        api: api,
        hostId: 'grandma',
        voice: voice ?? _Voice(),
        clock: () => DateTime.utc(2026, 10, 3, 2),
      ),
    ),
  );
  return api;
}

void main() {
  testWidgets('家人新增一個每天的文字提醒，儲存成功才顯示', (tester) async {
    final api = await _open(tester);
    api.at(_plan).add({});
    await tester.pump();
    await tester.tap(find.byKey(const Key('reminder-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('吃藥'));
    await tester.enterText(find.byKey(const Key('reminder-text')), '記得吃血壓藥');
    await tester.tap(find.byKey(const Key('reminder-done')));
    await tester.pumpAndSettle();
    final save = api.calls.singleWhere((c) => c.$1 == 'setReminderPlan').$2;
    expect(save['expectedVersion'], 0);
    expect(save['items'], [
      {
        'type': 'medicine',
        'repeat': 'daily',
        'time': '09:00',
        'text': '記得吃血壓藥',
      },
    ]);
    expect(find.text('已新增提醒'), findsOneWidget);
  });

  testWidgets('錄音提醒：按住錄音上傳後可試聽，只提醒一次帶日期', (tester) async {
    final voice = _Voice();
    final api = await _open(tester, voice: voice);
    api.at(_plan).add({'version': 2, 'items': []});
    await tester.pump();
    await tester.tap(find.byKey(const Key('reminder-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('只提醒一次'));
    await tester.pump();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('reminder-record'))),
    );
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(voice.log, ['start', 'stop']);
    await tester.tap(find.text('試聽'));
    await tester.pump();
    expect(voice.log.last, 'play');
    await tester.tap(find.byKey(const Key('reminder-done')));
    await tester.pumpAndSettle();
    final save = api.calls.lastWhere((c) => c.$1 == 'setReminderPlan').$2;
    expect(save['expectedVersion'], 2);
    final item = (save['items'] as List).single as Map;
    expect(item['repeat'], 'once');
    expect(item['date'], '2026-10-03');
    expect(item['voiceId'], 'v-1');
    expect(item['type'], 'custom');
  });

  testWidgets('刪除提醒需確認；儲存失敗不顯示成功', (tester) async {
    final api = await _open(tester);
    api.at(_plan).add({
      'version': 5,
      'items': [
        {
          'id': 'r-1',
          'type': 'water',
          'repeat': 'daily',
          'time': '14:00',
          'text': '喝水',
          'author': '小明',
        },
      ],
    });
    await tester.pump();
    expect(find.text('小明 設定'), findsOneWidget);
    api.failSave = StateError('網路中斷');
    await tester.tap(find.byTooltip('刪除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '刪除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('沒有儲存'), findsOneWidget);
    expect(find.text('已刪除提醒'), findsNothing);
    final save = api.calls.lastWhere((c) => c.$1 == 'setReminderPlan').$2;
    expect(save['items'], isEmpty);
    expect(save['expectedVersion'], 5);
  });

  testWidgets('我的聲音：錄自我介紹後才能加入早安輪流', (tester) async {
    final api = _Api();
    final voice = _Voice();
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ClientVoiceProfilePage(
            api: api,
            hostId: 'grandma',
            voice: voice,
          ),
        ),
      ),
    );
    api.at('care/grandma/voiceProfiles').add({
      'bob': {'name': '哥哥', 'joinWeather': true, 'introVoiceId': 'v-b'},
    });
    await tester.pump();
    expect(find.textContaining('目前輪流：哥哥'), findsOneWidget);
    final toggle = tester.widget<SwitchListTile>(
      find.byKey(const Key('join-weather')),
    );
    expect(toggle.onChanged, isNull, reason: 'needs an intro first');
    final g = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('intro-record'))),
    );
    await tester.pump(const Duration(milliseconds: 700));
    await g.up();
    await tester.pumpAndSettle();
    expect(api.calls.map((c) => c.$1), [
      'uploadReminderVoice',
      'setVoiceProfile',
    ]);
    await tester.tap(find.byKey(const Key('join-weather')));
    await tester.pumpAndSettle();
    final last = api.calls.last.$2;
    expect(last['joinWeather'], true);
    expect(last['introVoiceId'], 'v-1');
  });

  testWidgets('每週提醒要選星期幾，送出排序後的 days', (tester) async {
    final api = await _open(tester);
    api.at(_plan).add({'version': 1, 'items': []});
    await tester.pump();
    await tester.tap(find.byKey(const Key('reminder-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('每週幾天'));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('reminder-text')), '倒垃圾');
    await tester.tap(find.byKey(const Key('reminder-done')));
    await tester.pump();
    expect(find.text('請選擇星期幾'), findsOneWidget);
    await tester.tap(find.byKey(const Key('weekday-5')));
    await tester.tap(find.byKey(const Key('weekday-1')));
    await tester.tap(find.byKey(const Key('reminder-done')));
    await tester.pumpAndSettle();
    final item =
        (api.calls.lastWhere((c) => c.$1 == 'setReminderPlan').$2['items']
                    as List)
                .single
            as Map;
    expect(item['repeat'], 'weekly');
    expect(item['days'], [1, 5]);
  });

  final row = {
    'id': 'r-1',
    'type': 'water',
    'repeat': 'weekly',
    'days': [1, 3],
    'time': '14:00',
    'text': '喝水',
    'voiceId': 'v-9',
    'author': '小明',
    'editedBy': '哥哥',
  };

  testWidgets('暫停今天、複製保留錄音、顯示最後修改者', (tester) async {
    final api = await _open(tester);
    api.at(_plan).add({
      'version': 3,
      'items': [row],
    });
    await tester.pump();
    expect(find.textContaining('每週一、三'), findsOneWidget);
    expect(find.text('小明 設定・最後由 哥哥 修改'), findsOneWidget);
    await tester.tap(find.byKey(const Key('reminder-more-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('今天先暫停'));
    await tester.pumpAndSettle();
    var items =
        api.calls.lastWhere((c) => c.$1 == 'setReminderPlan').$2['items']
            as List;
    expect((items.single as Map)['pausedUntil'], '2026-10-03');
    expect((items.single as Map)['id'], 'r-1');
    await tester.tap(find.byKey(const Key('reminder-more-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('複製一個'));
    await tester.pumpAndSettle();
    items =
        api.calls.lastWhere((c) => c.$1 == 'setReminderPlan').$2['items']
            as List;
    expect(items, hasLength(2));
    expect((items.last as Map).containsKey('id'), isFalse);
    expect((items.last as Map)['voiceId'], 'v-9');
    expect((items.last as Map)['days'], [1, 3]);
  });

  testWidgets('其他家人先存了：把我的修改套到最新版本再存一次', (tester) async {
    final api = await _open(tester);
    api.at(_plan).add({
      'version': 3,
      'items': [row],
    });
    await tester.pump();
    api.failSave = FirebaseFunctionsException(
      code: 'aborted',
      message: '其他家人剛更新了提醒',
    );
    api.onFail = () => api.at(_plan).add({
      'version': 4,
      'items': [
        row,
        {'id': 'r-2', 'type': 'medicine', 'repeat': 'daily', 'time': '20:00'},
      ],
    });
    await tester.tap(find.byKey(const Key('reminder-more-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('今天先暫停'));
    await tester.pumpAndSettle();
    final saves = api.calls.where((c) => c.$1 == 'setReminderPlan').toList();
    expect(saves, hasLength(2));
    expect(saves.last.$2['expectedVersion'], 4);
    final items = saves.last.$2['items'] as List;
    expect(items.map((e) => (e as Map)['id']), ['r-1', 'r-2']);
    expect((items.first as Map)['pausedUntil'], '2026-10-03');
    expect(find.text('今天先不提醒，明天照常'), findsOneWidget);
  });

  testWidgets('我的聲音：可以完全不用自己的聲音（留言、提醒、早安都不播）', (tester) async {
    final api = _MeApi();
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ClientVoiceProfilePage(
            api: api,
            hostId: 'grandma',
            voice: _Voice(),
          ),
        ),
      ),
    );
    api.at('care/grandma/voiceProfiles').add({
      'me': {'name': '我', 'joinWeather': false, 'introVoiceId': 'v-me'},
    });
    await tester.pump();
    await tester.tap(find.byKey(const Key('intro-remove')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '不要用'));
    await tester.pumpAndSettle();
    final save = api.calls.lastWhere((c) => c.$1 == 'setVoiceProfile').$2;
    expect(save['introVoiceId'], isNull);
    expect(save['joinWeather'], false);
    expect(find.textContaining('已停用'), findsOneWidget);
    expect(find.text('按住錄自我介紹'), findsOneWidget);
  });
}
