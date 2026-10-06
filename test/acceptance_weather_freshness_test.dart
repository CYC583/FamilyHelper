// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';
import 'package:familyhelper/app/host/host_today_page.dart';
import 'package:familyhelper/app/common/weather_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final checkSpeech in [false, true]) {
    testWidgets(
      checkSpeech
          ? 'Listen Today must not speak yesterday forecast'
          : 'an open Today page does not keep yesterday forecast after date advances',
      (tester) async {
        String? spoken;
        const channel = MethodChannel('familyhelper/native');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            if (call.method == 'previewSpeak') {
              spoken = (call.arguments as Map)['text'] as String;
              return true;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        final settings = StreamController<Map<String, dynamic>>.broadcast(
          sync: true,
        );
        addTearDown(settings.close);
        var calls = 0;
        final weather = WeatherService(
          readJson: (_) async {
            calls++;
            return {
              'timezone': 'Asia/Taipei',
              'utc_offset_seconds': 28800,
              'current': {
                'time': calls == 1 ? '2026-10-02T23:30' : '2026-10-03T00:15',
                'temperature_2m': calls == 1 ? 30 : 20,
                'weather_code': 0,
              },
              'daily': {
                'time': [calls == 1 ? '2026-10-02' : '2026-10-03'],
                'temperature_2m_max': [31],
                'temperature_2m_min': [18],
              },
            };
          },
        );
        Widget page(DateTime now) => MaterialApp(
          home: Scaffold(
            body: HostTodayPage(
              hostUid: 'grandma',
              now: now,
              weather: weather,
              weatherSettings: settings.stream,
            ),
          ),
        );
        await tester.pumpWidget(page(DateTime.utc(2026, 10, 2, 15, 30)));
        settings.add({
          'timezone': 'Asia/Taipei',
          'city': {'name': '台北市', 'latitude': 25.03, 'longitude': 121.56},
        });
        await tester.pumpAndSettle();
        expect(find.text('台北市：30 度，晴朗'), findsOneWidget);
        await tester.pumpWidget(page(DateTime.utc(2026, 10, 2, 16, 15)));
        await tester.pumpAndSettle();
        if (checkSpeech) {
          await tester.tap(find.text('聽今天'));
          await tester.pumpAndSettle();
          expect(spoken, isNotNull);
          expect(
            spoken,
            isNot(contains('目前約 30 度')),
            reason: 'Do not speak previous day cached weather as today',
          );
        } else {
          expect(
            find.text('台北市：30 度，晴朗'),
            findsNothing,
            reason: 'Previous Taipei calendar day cannot remain today forecast',
          );
        }
        expect(calls, greaterThanOrEqualTo(2));
      },
    );
  }
}
