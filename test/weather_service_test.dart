// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:familyhelper/app/common/weather_service.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> sample({String time = '2026-10-02T13:00'}) => {
  'timezone': 'Asia/Taipei',
  'utc_offset_seconds': 28800,
  'current': {'time': time, 'temperature_2m': 30.4, 'weather_code': 51},
  'daily': {
    'time': ['2026-10-02'],
    'temperature_2m_max': [30.8],
    'temperature_2m_min': [23.1],
    'precipitation_probability_max': [99],
  },
};

void main() {
  const city = WeatherLocation('台北市', 25.03, 121.56);
  final now = DateTime.utc(2026, 10, 2, 5, 15);

  test('城市搜尋限定台灣並由家人明確選擇結果', () async {
    Uri? requested;
    final service = WeatherService(
      readJson: (uri) async {
        requested = uri;
        return {
          'results': [
            {
              'name': '臺北市',
              'country_code': 'TW',
              'latitude': 25.03,
              'longitude': 121.56,
            },
            {
              'name': '同名外國城市',
              'country_code': 'US',
              'latitude': 25,
              'longitude': 121,
            },
            {'name': '壞資料', 'country_code': 'TW', 'latitude': 999},
          ],
        };
      },
    );
    final cities = await service.searchTaiwanCities('臺北');
    expect(requested!.host, 'geocoding-api.open-meteo.com');
    expect(requested!.queryParameters['countryCode'], 'TW');
    expect(requested!.queryParameters['language'], 'zh');
    expect(cities, hasLength(1));
    expect(cities.single.name, '臺北市');
    expect(cities.single.latitude, 25.03);
    expect(await service.searchTaiwanCities('北'), isEmpty);
  });

  test('中文縣市無搜尋結果時改用羅馬拼音，不誤判為沒有台灣城市', () async {
    final queries = <String>[];
    final service = WeatherService(
      readJson: (uri) async {
        final name = uri.queryParameters['name']!;
        queries.add(name);
        if (name != 'Taipei') return {'results': <Object>[]};
        return {
          'results': [
            {
              'name': '台北市',
              'country_code': 'TW',
              'latitude': 25.05306,
              'longitude': 121.52639,
            },
          ],
        };
      },
    );
    final cities = await service.searchTaiwanCities('臺北市');
    expect(queries, ['臺北市', 'Taipei']);
    expect(cities.single.name, '台北市');
  });

  test('只用家人選定城市抓當天來源與更新時間，不用手機 GPS', () async {
    Uri? requested;
    final service = WeatherService(
      readJson: (uri) async {
        requested = uri;
        return sample();
      },
    );
    final report = await service.fetch(city, now: now);

    expect(requested!.host, 'api.open-meteo.com');
    expect(requested!.queryParameters['timezone'], 'Asia/Taipei');
    expect(requested!.queryParameters['latitude'], '25.03');
    expect(requested!.queryParameters['forecast_days'], '1');
    expect(report.observedAtUtc, DateTime.utc(2026, 10, 2, 5));
    expect(report.peakRainChance, 99);
    expect(report.spokenSummary, contains('台北市 天氣預報'));
    expect(report.spokenSummary, contains('目前約 30 度，有雨'));
    expect(report.spokenSummary, contains('來源 Open-Meteo'));
    expect(report.spokenSummary, contains('以實際天氣為準'));
  });

  test('過期資料、不同日期與異常格式都不能播成今天的準確天氣', () async {
    for (final body in [
      sample(time: '2026-10-02T09:00'),
      {
        ...sample(),
        'daily': {
          ...sample()['daily'] as Map,
          'time': ['2026-10-01'],
        },
      },
      {
        ...sample(),
        'current': {'time': '2026-10-02T13:00'},
      },
      {...sample(), 'timezone': 'UTC'},
    ]) {
      final service = WeatherService(readJson: (_) async => body);
      await expectLater(
        service.fetch(city, now: now),
        throwsA(isA<WeatherUnavailable>()),
      );
    }
  });

  test('斷網與城市未設定只回明確降級，不虛構天氣', () async {
    final offline = WeatherService(
      readJson: (_) async => throw StateError('offline'),
    );
    await expectLater(
      offline.fetch(city, now: now),
      throwsA(isA<WeatherUnavailable>()),
    );
    final invalid = WeatherService(readJson: (_) async => sample());
    await expectLater(
      invalid.fetch(const WeatherLocation('', 0, 0), now: now),
      throwsA(isA<WeatherUnavailable>()),
    );
  });
}
