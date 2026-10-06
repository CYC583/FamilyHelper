// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:familyhelper/app/common/daily_quote.dart';
import 'package:familyhelper/app/common/daily_quote_library.dart';
import 'package:familyhelper/app/host/host_today_page.dart';
import 'package:familyhelper/app/common/weather_service.dart';
import 'package:familyhelper/app/common/native_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('小手機與橫向 200% 文字可完整閱讀且底部導覽仍在', (tester) async {
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final quote = FamilyQuote(
      id: 'long',
      author: '孫女',
      createdAt: DateTime.utc(2026, 10, 1),
      text: '今天想和你說說話，看看窗外的光，等你方便的時候再拍一張照片給我們看看',
    );
    for (final size in [
      const Size(320, 568),
      const Size(360, 640),
      const Size(568, 320),
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: const TextScaler.linear(2),
            ),
            child: Scaffold(
              body: HostTodayPage(
                hostUid: 'grandma',
                now: DateTime.utc(2026, 10, 2),
                pendingFamily: [quote],
              ),
              bottomNavigationBar: const SizedBox(
                height: 80,
                child: Text('底部導覽'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$size');
      expect(find.text('底部導覽'), findsOneWidget);
      await tester.ensureVisible(find.text(quote.text));
      expect(tester.takeException(), isNull, reason: 'quote $size');
    }
  });

  testWidgets('今天分頁直接顯示固定每日一句，無須尋找捲動後的按鈕', (tester) async {
    final instant = DateTime.utc(2026, 10, 1, 17); // Taipei 10/2 01:00.
    final expected = pickDailyQuote(
      date: DateTime(2026, 10, 2),
      seed: 'grandma',
      library: builtInQuotes,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HostTodayPage(hostUid: 'grandma', now: instant),
        ),
      ),
    );
    expect(find.text('每日一句'), findsOneWidget);
    expect(find.text(expected.text), findsOneWidget);
  });

  testWidgets('尚無家人天氣設定時明確標示，仍顯示每日一句', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: HostTodayPage(hostUid: 'grandma')),
      ),
    );
    expect(find.text('家人尚未設定天氣城市'), findsOneWidget);
    expect(find.text('每日一句'), findsOneWidget);
  });

  testWidgets('只顯示家人設定城市的有效當日預報與來源時間', (tester) async {
    Uri? requested;
    final weather = WeatherService(
      readJson: (uri) async {
        requested = uri;
        return {
          'timezone': 'Asia/Taipei',
          'utc_offset_seconds': 28800,
          'current': {
            'time': '2026-10-02T13:00',
            'temperature_2m': 30.4,
            'weather_code': 51,
          },
          'daily': {
            'time': ['2026-10-02'],
            'temperature_2m_max': [30.8],
            'temperature_2m_min': [23.1],
            'precipitation_probability_max': [99],
          },
        };
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HostTodayPage(
            hostUid: 'grandma',
            now: DateTime.utc(2026, 10, 2, 5, 15),
            weather: weather,
            weatherSettings: Stream.value({
              'city': {'name': '台北市', 'latitude': 25.03, 'longitude': 121.56},
              'timezone': 'Asia/Taipei',
              'morningTime': '08:30',
            }),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(requested?.host, 'api.open-meteo.com');
    expect(requested?.queryParameters['latitude'], '25.03');
    expect(find.text('台北市：30 度，有雨'), findsOneWidget);
    expect(find.textContaining('Open-Meteo 預報'), findsOneWidget);
    expect(find.textContaining('更新 今天 13:00'), findsOneWidget);
    expect(find.text('每日一句'), findsOneWidget);
  });

  testWidgets('天氣服務失敗只顯示錯誤與每日一句，不假裝有天氣', (tester) async {
    final weather = WeatherService(
      readJson: (_) async => throw StateError('offline'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HostTodayPage(
            hostUid: 'grandma',
            now: DateTime.utc(2026, 10, 2, 5, 15),
            weather: weather,
            weatherSettings: Stream.value({
              'city': {'name': '台北市', 'latitude': 25.03, 'longitude': 121.56},
              'timezone': 'Asia/Taipei',
            }),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('天氣服務暫時無法使用；今天先不播報天氣'), findsOneWidget);
    expect(find.text('台北市：30 度，有雨'), findsNothing);
    expect(find.text('每日一句'), findsOneWidget);
  });

  testWidgets('家人更換城市後，較舊請求晚到不得蓋過新城市', (tester) async {
    final settings = StreamController<Map<String, dynamic>>();
    final oldReply = Completer<Map<String, dynamic>>();
    addTearDown(settings.close);
    Map<String, dynamic> sample(String temperature) => {
      'timezone': 'Asia/Taipei',
      'utc_offset_seconds': 28800,
      'current': {
        'time': '2026-10-02T13:00',
        'temperature_2m': double.parse(temperature),
        'weather_code': 0,
      },
      'daily': {
        'time': ['2026-10-02'],
        'temperature_2m_max': [31],
        'temperature_2m_min': [22],
      },
    };
    final weather = WeatherService(
      readJson: (uri) async {
        if (uri.queryParameters['latitude'] == '25.03') return oldReply.future;
        return sample('25');
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HostTodayPage(
            hostUid: 'grandma',
            now: DateTime.utc(2026, 10, 2, 5, 15),
            weather: weather,
            weatherSettings: settings.stream,
          ),
        ),
      ),
    );
    settings.add({
      'timezone': 'Asia/Taipei',
      'city': {'name': '台北市', 'latitude': 25.03, 'longitude': 121.56},
    });
    await tester.pump();
    settings.add({
      'timezone': 'Asia/Taipei',
      'city': {'name': '高雄市', 'latitude': 22.62, 'longitude': 120.30},
    });
    await tester.pumpAndSettle();
    expect(find.text('高雄市：25 度，晴朗'), findsOneWidget);
    oldReply.complete(sample('30'));
    await tester.pumpAndSettle();
    expect(find.text('高雄市：25 度，晴朗'), findsOneWidget);
    expect(find.textContaining('台北市：30'), findsNothing);
  });

  testWidgets('無有效天氣時朗讀每日一句，不虛構天氣內容', (tester) async {
    String? spoken;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, (call) async {
          if (call.method == 'previewSpeak') {
            spoken = (call.arguments as Map)['text'] as String;
            return true;
          }
          throw PlatformException(code: 'UNEXPECTED');
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeBridge.channel, null),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: HostTodayPage(hostUid: 'grandma')),
      ),
    );
    await tester.tap(find.text('聽今天'));
    await tester.pump();
    expect(spoken, isNotNull);
    expect(spoken, contains('每日一句'));
    expect(spoken, isNot(contains('天氣預報')));
    expect(find.text('已開始朗讀'), findsOneWidget);
  });

  testWidgets('有效天氣才與每日一句一起朗讀；語音不可用有可見錯誤', (tester) async {
    String? spoken;
    var unavailable = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, (call) async {
          if (call.method != 'previewSpeak') {
            throw PlatformException(code: 'UNEXPECTED');
          }
          spoken = (call.arguments as Map)['text'] as String;
          if (unavailable) {
            throw PlatformException(
              code: 'TTS_UNAVAILABLE',
              message: '請確認已安裝中文語音服務',
            );
          }
          return true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeBridge.channel, null),
    );
    final weather = WeatherService(
      readJson: (_) async => {
        'timezone': 'Asia/Taipei',
        'utc_offset_seconds': 28800,
        'current': {
          'time': '2026-10-02T13:00',
          'temperature_2m': 25,
          'weather_code': 0,
        },
        'daily': {
          'time': ['2026-10-02'],
          'temperature_2m_max': [28],
          'temperature_2m_min': [22],
        },
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HostTodayPage(
            hostUid: 'grandma',
            now: DateTime.utc(2026, 10, 2, 5, 15),
            weather: weather,
            weatherSettings: Stream.value({
              'city': {'name': '台北市', 'latitude': 25.03, 'longitude': 121.56},
              'timezone': 'Asia/Taipei',
            }),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('聽今天'));
    await tester.pump();
    expect(spoken, contains('台北市 天氣預報'));
    expect(spoken, contains('每日一句'));
    unavailable = true;
    await tester.tap(find.text('聽今天'));
    await tester.pump();
    expect(find.text('請確認已安裝中文語音服務'), findsOneWidget);
  });

  testWidgets('跨台北午夜立即隱藏舊預報，朗讀不含昨天氣溫', (tester) async {
    final settings = StreamController<Map<String, dynamic>>.broadcast(
      sync: true,
    );
    final nextDayResponse = Completer<Map<String, dynamic>>();
    addTearDown(settings.close);
    String? spoken;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, (call) async {
          if (call.method != 'previewSpeak') {
            throw PlatformException(code: 'UNEXPECTED');
          }
          spoken = (call.arguments as Map)['text'] as String;
          return true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeBridge.channel, null),
    );
    var requests = 0;
    Map<String, dynamic> response(String day, String time, int temperature) => {
      'timezone': 'Asia/Taipei',
      'utc_offset_seconds': 28800,
      'current': {
        'time': '${day}T$time',
        'temperature_2m': temperature,
        'weather_code': 0,
      },
      'daily': {
        'time': [day],
        'temperature_2m_max': [31],
        'temperature_2m_min': [18],
      },
    };
    final weather = WeatherService(
      readJson: (_) {
        requests++;
        if (requests == 1) {
          return Future.value(response('2026-10-02', '23:30', 30));
        }
        return nextDayResponse.future;
      },
    );
    Widget today(DateTime instant) => MaterialApp(
      home: Scaffold(
        body: HostTodayPage(
          hostUid: 'grandma',
          now: instant,
          weather: weather,
          weatherSettings: settings.stream,
        ),
      ),
    );
    await tester.pumpWidget(today(DateTime.utc(2026, 10, 2, 15, 30)));
    settings.add({
      'city': {'name': '台北市', 'latitude': 25.03, 'longitude': 121.56},
      'timezone': 'Asia/Taipei',
    });
    await tester.pumpAndSettle();
    expect(find.text('台北市：30 度，晴朗'), findsOneWidget);

    await tester.pumpWidget(today(DateTime.utc(2026, 10, 2, 16, 15)));
    await tester.pump();
    expect(find.text('台北市：30 度，晴朗'), findsNothing);
    expect(requests, 2);
    await tester.tap(find.text('聽今天'));
    await tester.pump();
    expect(spoken, contains('每日一句'));
    expect(spoken, isNot(contains('目前約 30 度')));

    nextDayResponse.complete(response('2026-10-03', '00:15', 20));
    await tester.pumpAndSettle();
    expect(find.text('台北市：20 度，晴朗'), findsOneWidget);
  });

  testWidgets('今天頁保持開啟跨午夜時自動換日，不朗讀舊預報', (tester) async {
    var current = DateTime.utc(2026, 10, 2, 15, 55);
    var requests = 0;
    String? spoken;
    final settings = StreamController<Map<String, dynamic>>.broadcast(
      sync: true,
    );
    addTearDown(settings.close);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, (call) async {
          if (call.method != 'previewSpeak') {
            throw PlatformException(code: 'UNEXPECTED');
          }
          spoken = (call.arguments as Map)['text'] as String;
          return true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeBridge.channel, null),
    );
    final weather = WeatherService(
      readJson: (_) async {
        requests++;
        final firstDay = requests == 1;
        return {
          'timezone': 'Asia/Taipei',
          'utc_offset_seconds': 28800,
          'current': {
            'time': firstDay ? '2026-10-02T23:55' : '2026-10-03T00:00',
            'temperature_2m': firstDay ? 30 : 20,
            'weather_code': 0,
          },
          'daily': {
            'time': [firstDay ? '2026-10-02' : '2026-10-03'],
            'temperature_2m_max': [31],
            'temperature_2m_min': [18],
          },
        };
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HostTodayPage(
            hostUid: 'grandma',
            clock: () => current,
            weather: weather,
            weatherSettings: settings.stream,
          ),
        ),
      ),
    );
    settings.add({
      'city': {'name': '台北市', 'latitude': 25.03, 'longitude': 121.56},
      'timezone': 'Asia/Taipei',
    });
    await tester.pumpAndSettle();
    expect(find.text('台北市：30 度，晴朗'), findsOneWidget);

    current = DateTime.utc(2026, 10, 2, 16);
    await tester.pump(const Duration(minutes: 5));
    await tester.pumpAndSettle();
    expect(requests, greaterThanOrEqualTo(2));
    expect(find.text('台北市：30 度，晴朗'), findsNothing);
    await tester.tap(find.text('聽今天'));
    await tester.pump();
    expect(spoken, isNot(contains('目前約 30 度')));
  });

  testWidgets('午夜更新計時器延後時，按聽今天也不得朗讀昨天氣溫', (tester) async {
    var current = DateTime.utc(2026, 10, 2, 15, 55);
    String? spoken;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, (call) async {
          if (call.method != 'previewSpeak') {
            throw PlatformException(code: 'UNEXPECTED');
          }
          spoken = (call.arguments as Map)['text'] as String;
          return true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeBridge.channel, null),
    );
    final weather = WeatherService(
      readJson: (_) async => {
        'timezone': 'Asia/Taipei',
        'utc_offset_seconds': 28800,
        'current': {
          'time': '2026-10-02T23:55',
          'temperature_2m': 30,
          'weather_code': 0,
        },
        'daily': {
          'time': ['2026-10-02'],
          'temperature_2m_max': [31],
          'temperature_2m_min': [18],
        },
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HostTodayPage(
            hostUid: 'grandma',
            clock: () => current,
            weather: weather,
            weatherSettings: Stream.value({
              'city': {'name': '台北市', 'latitude': 25.03, 'longitude': 121.56},
              'timezone': 'Asia/Taipei',
            }),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('台北市：30 度，晴朗'), findsOneWidget);
    current = DateTime.utc(2026, 10, 2, 16, 1);
    // Deliberately do not advance fake timers or rebuild the widget.
    await tester.tap(find.text('聽今天'));
    await tester.pump();
    expect(spoken, contains('每日一句'));
    expect(spoken, isNot(contains('目前約 30 度')));
  });

  testWidgets('從背景回到今天頁時重新檢查跨日天氣', (tester) async {
    var current = DateTime.utc(2026, 10, 2, 15, 55);
    var requests = 0;
    final weather = WeatherService(
      readJson: (_) async {
        requests++;
        final firstDay = requests == 1;
        return {
          'timezone': 'Asia/Taipei',
          'utc_offset_seconds': 28800,
          'current': {
            'time': firstDay ? '2026-10-02T23:55' : '2026-10-03T00:10',
            'temperature_2m': firstDay ? 30 : 20,
            'weather_code': 0,
          },
          'daily': {
            'time': [firstDay ? '2026-10-02' : '2026-10-03'],
            'temperature_2m_max': [31],
            'temperature_2m_min': [18],
          },
        };
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HostTodayPage(
            hostUid: 'grandma',
            clock: () => current,
            weather: weather,
            weatherSettings: Stream.value({
              'city': {'name': '台北市', 'latitude': 25.03, 'longitude': 121.56},
              'timezone': 'Asia/Taipei',
            }),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('台北市：30 度，晴朗'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    current = DateTime.utc(2026, 10, 2, 16, 10);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(requests, 2);
    expect(find.text('台北市：20 度，晴朗'), findsOneWidget);
  });

  testWidgets('家人提供的一句話優先顯示來源', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HostTodayPage(
            hostUid: 'grandma',
            now: DateTime.utc(2026, 10, 2),
            pendingFamily: [
              FamilyQuote(
                id: 'one',
                text: '今天想你了',
                author: '孫子',
                createdAt: DateTime.utc(2026, 10, 1),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('今天想你了'), findsOneWidget);
    expect(find.text('來自 孫子'), findsOneWidget);
  });
}
