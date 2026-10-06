// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:convert';
import 'dart:io';

/// A family-selected city, not a GPS reading. The caller owns the city list
/// and must not silently substitute a different place when a lookup fails.
class WeatherLocation {
  final String name;
  final double latitude;
  final double longitude;

  const WeatherLocation(this.name, this.latitude, this.longitude);
}

class WeatherUnavailable implements Exception {
  final String message;
  const WeatherUnavailable(this.message);
  @override
  String toString() => message;
}

class WeatherReport {
  final String city;
  final DateTime observedAtUtc;
  final double temperatureC;
  final int weatherCode;
  final double highC;
  final double lowC;
  final int? peakRainChance;

  const WeatherReport({
    required this.city,
    required this.observedAtUtc,
    required this.temperatureC,
    required this.weatherCode,
    required this.highC,
    required this.lowC,
    this.peakRainChance,
  });

  String get condition {
    if (weatherCode == 0) return '晴朗';
    if (weatherCode <= 2) return '晴時多雲';
    if (weatherCode == 3) return '多雲';
    if (weatherCode == 45 || weatherCode == 48) return '有霧';
    if (weatherCode >= 51 && weatherCode <= 67) return '有雨';
    if (weatherCode >= 71 && weatherCode <= 77) return '有雪';
    if (weatherCode >= 80 && weatherCode <= 82) return '有陣雨';
    if (weatherCode >= 85 && weatherCode <= 86) return '有陣雪';
    if (weatherCode >= 95 && weatherCode <= 99) return '有雷雨';
    return '天氣狀況待確認';
  }

  /// Do not describe model output as certain or as a live observation.
  String get spokenSummary {
    final chance = peakRainChance == null ? '' : '，今天時段最高降雨機率 $peakRainChance%';
    return '$city 天氣預報：目前約 ${temperatureC.round()} 度，$condition。'
        '今天最高約 ${highC.round()} 度，最低約 ${lowC.round()} 度$chance。'
        '資料來源 Open-Meteo，請以實際天氣為準。';
  }
}

typedef WeatherJsonReader = Future<Map<String, dynamic>> Function(Uri uri);

class WeatherService {
  final WeatherJsonReader readJson;
  const WeatherService({this.readJson = _readJson});

  static const _cityAliases = <String, String>{
    '台北': 'Taipei',
    '新北': 'New Taipei',
    '桃園': 'Taoyuan',
    '台中': 'Taichung',
    '台南': 'Tainan',
    '高雄': 'Kaohsiung',
    '基隆': 'Keelung',
    '新竹': 'Hsinchu',
    '苗栗': 'Miaoli',
    '彰化': 'Changhua',
    '南投': 'Nantou',
    '雲林': 'Yunlin',
    '嘉義': 'Chiayi',
    '屏東': 'Pingtung',
    '宜蘭': 'Yilan',
    '花蓮': 'Hualien',
    '台東': 'Taitung',
    '澎湖': 'Penghu',
    '金門': 'Kinmen',
    '連江': 'Lienchiang',
  };

  /// Families choose a returned Taiwan place explicitly; a search result is
  /// never silently treated as the elder's current GPS location.
  Future<List<WeatherLocation>> searchTaiwanCities(String query) async {
    final name = query.trim();
    if (name.runes.length < 2 || name.runes.length > 40) return const [];
    final first = await _searchOnce(name);
    if (first.isNotEmpty) return first;
    // Open-Meteo's geocoding currently localizes results to Chinese but does
    // not reliably index Chinese input. Retry common county/city names in the
    // indexed romanization; still show the returned Chinese name for choice.
    final normalized = name
        .replaceAll('臺', '台')
        .replaceFirst(RegExp(r'[市縣]$'), '');
    final alias = _cityAliases[normalized];
    return alias == null ? const [] : _searchOnce(alias);
  }

  Future<List<WeatherLocation>> _searchOnce(String name) async {
    final uri = Uri.https('geocoding-api.open-meteo.com', '/v1/search', {
      'name': name,
      'count': '8',
      'language': 'zh',
      'countryCode': 'TW',
    });
    final Map<String, dynamic> body;
    try {
      body = await readJson(uri).timeout(const Duration(seconds: 10));
    } catch (_) {
      throw const WeatherUnavailable('城市搜尋暫時無法使用，請稍後再試');
    }
    if (body['error'] == true) {
      throw const WeatherUnavailable('城市搜尋暫時無法使用，請稍後再試');
    }
    final results = body['results'];
    if (results == null) return const [];
    if (results is! List) {
      throw const WeatherUnavailable('城市資料格式不正確');
    }
    final cities = <WeatherLocation>[];
    for (final item in results) {
      if (item is! Map || item['country_code'] != 'TW') continue;
      final name = item['name'];
      final latitude = item['latitude'];
      final longitude = item['longitude'];
      if (name is! String ||
          name.trim().isEmpty ||
          latitude is! num ||
          longitude is! num ||
          !latitude.isFinite ||
          !longitude.isFinite ||
          latitude.abs() > 90 ||
          longitude.abs() > 180) {
        continue;
      }
      final admin = item['admin1'];
      final label = admin is String && admin.isNotEmpty && admin != name
          ? '$name，$admin'
          : name;
      cities.add(
        WeatherLocation(label, latitude.toDouble(), longitude.toDouble()),
      );
    }
    return cities;
  }

  Future<WeatherReport> fetch(
    WeatherLocation city, {
    required DateTime now,
  }) async {
    if (city.name.trim().isEmpty ||
        !city.latitude.isFinite ||
        !city.longitude.isFinite ||
        city.latitude.abs() > 90 ||
        city.longitude.abs() > 180) {
      throw const WeatherUnavailable('請先選擇有效的天氣城市');
    }
    final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': city.latitude.toString(),
      'longitude': city.longitude.toString(),
      'current': 'temperature_2m,weather_code',
      'daily':
          'temperature_2m_max,temperature_2m_min,precipitation_probability_max',
      'timezone': 'Asia/Taipei',
      'forecast_days': '1',
    });
    final Map<String, dynamic> body;
    try {
      body = await readJson(uri).timeout(const Duration(seconds: 10));
    } catch (_) {
      throw const WeatherUnavailable('天氣服務暫時無法使用；今天先不播報天氣');
    }
    if (body['error'] == true || body['timezone'] != 'Asia/Taipei') {
      throw const WeatherUnavailable('天氣資料暫時無法確認；今天先不播報天氣');
    }
    final offset = body['utc_offset_seconds'];
    final current = body['current'];
    final daily = body['daily'];
    if (offset is! int ||
        current is! Map ||
        daily is! Map ||
        current['time'] is! String ||
        current['temperature_2m'] is! num ||
        current['weather_code'] is! num ||
        daily['time'] is! List ||
        daily['temperature_2m_max'] is! List ||
        daily['temperature_2m_min'] is! List) {
      throw const WeatherUnavailable('天氣資料格式不完整；今天先不播報天氣');
    }
    final localTime = DateTime.tryParse('${current['time']}Z');
    final date = _dateInOffset(now.toUtc(), offset);
    final day = _first(daily['time']);
    final high = _first(daily['temperature_2m_max']);
    final low = _first(daily['temperature_2m_min']);
    final temperature = (current['temperature_2m'] as num).toDouble();
    final code = (current['weather_code'] as num).toInt();
    if (localTime == null ||
        day != date ||
        high is! num ||
        low is! num ||
        !high.isFinite ||
        !low.isFinite ||
        !temperature.isFinite ||
        code < 0 ||
        code > 99) {
      throw const WeatherUnavailable('天氣資料不是今天的有效預報；今天先不播報天氣');
    }
    final observedAt = localTime.subtract(Duration(seconds: offset));
    final age = now.toUtc().difference(observedAt);
    if (age < const Duration(minutes: -15) || age > const Duration(hours: 2)) {
      throw const WeatherUnavailable('天氣資料已過期；今天先不播報天氣');
    }
    final rawChance = _first(daily['precipitation_probability_max']);
    final chance =
        rawChance is num &&
            rawChance.isFinite &&
            rawChance >= 0 &&
            rawChance <= 100
        ? rawChance.round()
        : null;
    return WeatherReport(
      city: city.name.trim(),
      observedAtUtc: observedAt,
      temperatureC: temperature,
      weatherCode: code,
      highC: high.toDouble(),
      lowC: low.toDouble(),
      peakRainChance: chance,
    );
  }

  static Object? _first(Object? value) =>
      value is List && value.isNotEmpty ? value.first : null;

  static String _dateInOffset(DateTime utc, int seconds) {
    final local = utc.add(Duration(seconds: seconds));
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }
}

Future<Map<String, dynamic>> _readJson(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final request = await client.getUrl(uri);
    final response = await request.close().timeout(const Duration(seconds: 8));
    if (response.statusCode != HttpStatus.ok ||
        response.contentLength > 64 * 1024) {
      throw const WeatherUnavailable('天氣服務沒有回傳可用資料');
    }
    final bytes = await response.fold<List<int>>(<int>[], (buffer, chunk) {
      if (buffer.length + chunk.length > 64 * 1024) {
        throw const WeatherUnavailable('天氣資料過大');
      }
      return buffer..addAll(chunk);
    });
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      throw const WeatherUnavailable('天氣資料格式不正確');
    }
    return decoded;
  } finally {
    client.close(force: true);
  }
}
