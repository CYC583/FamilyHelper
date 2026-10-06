// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:familyhelper/app/client/client_weather_settings_page.dart';
import 'package:familyhelper/app/common/firebase_service.dart';
import 'package:familyhelper/app/common/weather_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Api extends FirebaseService {
  final settings = StreamController<Map<String, dynamic>>.broadcast();
  final calls = <Map<String, dynamic>>[];
  Object? failure;

  @override
  Stream<Map<String, dynamic>> watch(String path) {
    expect(path, 'care/grandma/settings/weather');
    return settings.stream;
  }

  @override
  Future<Map<String, dynamic>> call(
    String name, [
    Map<String, dynamic> data = const {},
  ]) async {
    expect(name, 'setWeatherSettings');
    calls.add(data);
    if (failure != null) throw failure!;
    return {'version': 1};
  }
}

void main() {
  final weather = WeatherService(
    readJson: (_) async => {
      'results': [
        {
          'name': '臺北市',
          'country_code': 'TW',
          'latitude': 25.03,
          'longitude': 121.56,
        },
      ],
    },
  );

  testWidgets('家人選城市與時間後才儲存；不把設定冒稱已自動播報', (tester) async {
    final api = _Api();
    addTearDown(api.settings.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ClientWeatherSettingsPage(
            api: api,
            hostId: 'grandma',
            weather: weather,
          ),
        ),
      ),
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    api.settings.add({});
    await tester.pump();

    await tester.enterText(find.byType(TextField), '臺北');
    await tester.tap(find.text('搜尋城市'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('臺北市').first);
    await tester.pump();
    expect(find.text('選擇：臺北市'), findsOneWidget);

    await tester.tap(find.text('儲存城市與時間'));
    await tester.pumpAndSettle();
    expect(api.calls, hasLength(1));
    expect(api.calls.single['hostId'], 'grandma');
    expect(api.calls.single['expectedVersion'], 0);
    expect(api.calls.single['morningTime'], '08:30');
    expect(api.calls.single['city'], {
      'name': '臺北市',
      'latitude': 25.03,
      'longitude': 121.56,
    });
    expect(find.textContaining('長輩要在自己的手機開啟'), findsOneWidget);
  });

  testWidgets('儲存失敗不顯示成功，也不丟掉已選城市', (tester) async {
    final api = _Api()..failure = StateError('設定衝突');
    addTearDown(api.settings.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ClientWeatherSettingsPage(
            api: api,
            hostId: 'grandma',
            weather: weather,
          ),
        ),
      ),
    );
    api.settings.add({
      'version': 2,
      'city': {'name': '新竹市', 'latitude': 24.8, 'longitude': 120.9},
      'morningTime': '09:15',
    });
    await tester.pump();
    await tester.tap(find.text('儲存城市與時間'));
    await tester.pumpAndSettle();
    expect(api.calls.single['expectedVersion'], 2);
    expect(api.calls.single['morningTime'], '09:15');
    expect(find.textContaining('設定衝突'), findsOneWidget);
    expect(find.textContaining('已儲存到家人設定'), findsNothing);
    expect(find.text('選擇：新竹市'), findsOneWidget);
  });

  testWidgets('編輯期間其他家人更新，送出仍使用開始編輯的版本', (tester) async {
    final api = _Api();
    addTearDown(api.settings.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ClientWeatherSettingsPage(
            api: api,
            hostId: 'grandma',
            weather: weather,
          ),
        ),
      ),
    );
    api.settings.add({'version': 2});
    await tester.pump();
    await tester.enterText(find.byType(TextField), '臺北');
    await tester.tap(find.text('搜尋城市'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('臺北市').first);
    await tester.pump();
    api.settings.add({'version': 3});
    await tester.pump();
    await tester.tap(find.text('儲存城市與時間'));
    await tester.pumpAndSettle();
    expect(api.calls.single['expectedVersion'], 2);
  });
}
