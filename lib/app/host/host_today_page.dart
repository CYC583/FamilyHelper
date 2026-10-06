// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:flutter/material.dart';

import '../common/daily_quote.dart';
import '../common/daily_quote_library.dart';
import '../common/firebase_service.dart';
import '../common/native_bridge.dart';
import '../common/weather_service.dart';
import 'host_care_panel.dart';
import 'package:flutter/services.dart';
import '../common/ui/fh_tokens.dart';
import '../common/ui/fh_format.dart';
import '../common/ui/fh_widgets.dart';

/// The host home keeps its two primary help buttons; this secondary page can
/// scroll at large text sizes without moving the bottom navigation.
class HostTodayPage extends StatefulWidget {
  final String hostUid;
  final DateTime? now;
  final DateTime Function()? clock;
  final List<FamilyQuote> pendingFamily;
  final Stream<Map<String, dynamic>>? weatherSettings;
  final WeatherService weather;
  final FirebaseService? api;

  /// Grandma's app hides weather and the daily quote (they are read aloud in
  /// the morning instead); previews and tests keep them visible.
  final bool showWeatherAndQuote;

  const HostTodayPage({
    super.key,
    required this.hostUid,
    this.now,
    this.clock,
    this.pendingFamily = const [],
    this.weatherSettings,
    this.weather = const WeatherService(),
    this.api,
    this.showWeatherAndQuote = true,
  });

  @override
  State<HostTodayPage> createState() => _HostTodayPageState();
}

class _HostTodayPageState extends State<HostTodayPage>
    with WidgetsBindingObserver {
  StreamSubscription<Map<String, dynamic>>? _settingsSubscription;
  WeatherLocation? _city;
  WeatherReport? _report;
  String _weatherStatus = '家人尚未設定天氣城市';
  int _requestId = 0;
  Timer? _refreshTimer;
  Timer? _quoteTimer;
  bool _startingSpeech = false;
  String? _speechStatus;

  DateTime get _now => widget.clock?.call() ?? widget.now ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listenForSettings();
    _scheduleQuoteRollover();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    setState(() {});
    _scheduleQuoteRollover();
    final city = _city;
    if (city != null && !_reportIsCurrent(_now)) _fetchWeather(city);
  }

  @override
  void didUpdateWidget(covariant HostTodayPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.now != widget.now || oldWidget.clock != widget.clock) {
      _scheduleQuoteRollover();
    }
    if (oldWidget.hostUid != widget.hostUid ||
        oldWidget.weatherSettings != widget.weatherSettings ||
        oldWidget.api != widget.api) {
      _settingsSubscription?.cancel();
      _refreshTimer?.cancel();
      _refreshTimer = null;
      _requestId++;
      _city = null;
      _report = null;
      _listenForSettings();
    } else if (oldWidget.now != widget.now &&
        _city != null &&
        !_reportIsCurrent(_now)) {
      _fetchWeather(_city!);
    }
  }

  void _scheduleQuoteRollover() {
    _quoteTimer?.cancel();
    // A fixed instant is used by static previews/tests; a live clock keeps
    // daily quotes current even if weather is unset or its stream fails.
    if (widget.now != null && widget.clock == null) return;
    final instant = _now.toUtc();
    final taipei = instant.add(const Duration(hours: 8));
    final midnight = DateTime.utc(
      taipei.year,
      taipei.month,
      taipei.day + 1,
    ).subtract(const Duration(hours: 8));
    final delay = midnight.difference(instant);
    _quoteTimer = Timer(
      delay > Duration.zero ? delay : const Duration(milliseconds: 1),
      () {
        if (!mounted) return;
        setState(() {});
        _scheduleQuoteRollover();
      },
    );
  }

  bool _reportIsCurrent(DateTime now) {
    final report = _report;
    if (report == null) return false;
    final instant = now.toUtc();
    final observed = report.observedAtUtc.toUtc();
    final age = instant.difference(observed);
    if (age < const Duration(minutes: -15) || age > const Duration(hours: 2)) {
      return false;
    }
    final taipeiNow = instant.add(const Duration(hours: 8));
    final taipeiObserved = observed.add(const Duration(hours: 8));
    return taipeiNow.year == taipeiObserved.year &&
        taipeiNow.month == taipeiObserved.month &&
        taipeiNow.day == taipeiObserved.day;
  }

  void _listenForSettings() {
    final stream =
        widget.weatherSettings ??
        widget.api?.watch('care/${widget.hostUid}/settings/weather');
    if (stream == null) {
      _weatherStatus = '家人尚未設定天氣城市';
      return;
    }
    _weatherStatus = '正在讀取天氣設定…';
    _settingsSubscription = stream.listen(
      _applySettings,
      onError: (Object _) {
        if (!mounted) return;
        _requestId++;
        _refreshTimer?.cancel();
        _refreshTimer = null;
        setState(() {
          _city = null;
          _report = null;
          _weatherStatus = '天氣設定暫時無法讀取；每日一句照常顯示';
        });
      },
    );
  }

  void _applySettings(Map<String, dynamic> settings) {
    final raw = settings['city'];
    if (raw is! Map ||
        settings['timezone'] != 'Asia/Taipei' ||
        raw['name'] is! String ||
        raw['latitude'] is! num ||
        raw['longitude'] is! num) {
      _requestId++;
      _refreshTimer?.cancel();
      _refreshTimer = null;
      setState(() {
        _city = null;
        _report = null;
        _weatherStatus = '家人尚未設定天氣城市';
      });
      return;
    }
    final city = WeatherLocation(
      raw['name'] as String,
      (raw['latitude'] as num).toDouble(),
      (raw['longitude'] as num).toDouble(),
    );
    if (_city?.name == city.name &&
        _city?.latitude == city.latitude &&
        _city?.longitude == city.longitude &&
        _report != null) {
      return;
    }
    _city = city;
    _fetchWeather(city);
  }

  Future<void> _fetchWeather(WeatherLocation city) async {
    final requestId = ++_requestId;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    setState(() {
      _report = null;
      _weatherStatus = '正在確認今日天氣…';
    });
    try {
      final report = await widget.weather.fetch(city, now: _now);
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _report = report;
        _weatherStatus = '';
      });
      _scheduleRefresh();
    } catch (error) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _report = null;
        _weatherStatus = error is WeatherUnavailable
            ? error.message
            : '天氣服務暫時無法使用；今天先不播報天氣';
      });
      _scheduleRefresh();
    }
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    if (widget.now != null || _city == null) return;
    final now = _now.toUtc();
    var next = now.add(const Duration(minutes: 30));
    final report = _report;
    if (report != null) {
      final expiry = report.observedAtUtc.toUtc().add(const Duration(hours: 2));
      final taipeiNow = now.add(const Duration(hours: 8));
      final midnight = DateTime.utc(
        taipeiNow.year,
        taipeiNow.month,
        taipeiNow.day + 1,
      ).subtract(const Duration(hours: 8));
      if (expiry.isBefore(next)) next = expiry;
      if (midnight.isBefore(next)) next = midnight;
    }
    final wait = next.difference(now);
    _refreshTimer = Timer(
      wait > Duration.zero ? wait : const Duration(milliseconds: 1),
      () {
        final city = _city;
        if (mounted && city != null) _fetchWeather(city);
      },
    );
  }

  void _retrySettings() {
    _settingsSubscription?.cancel();
    setState(() => _weatherStatus = '正在讀取天氣設定…');
    _listenForSettings();
  }

  Future<void> _readToday() async {
    // The wall clock can cross midnight before the next scheduled frame. Do
    // not capture weather speech from build: validate it again at the tap.
    final instant = _now;
    final quote = pickDailyQuote(
      date: instant.toUtc().add(const Duration(hours: 8)),
      seed: widget.hostUid,
      library: builtInQuotes,
      pendingFamily: widget.pendingFamily,
    );
    final report = _reportIsCurrent(instant) ? _report : null;
    final text = report == null
        ? '每日一句。${quote.text}'
        : '${report.spokenSummary} 每日一句。${quote.text}';
    setState(() {
      _startingSpeech = true;
      _speechStatus = null;
    });
    try {
      final started = await NativeBridge.previewSpeak(text);
      if (!mounted) return;
      setState(() => _speechStatus = started ? '已開始朗讀' : '朗讀未能開始');
    } catch (error) {
      if (!mounted) return;
      setState(
        () =>
            _speechStatus = error is PlatformException && error.message != null
            ? error.message
            : '無法朗讀，請檢查中文語音服務',
      );
    } finally {
      if (mounted) setState(() => _startingSpeech = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _quoteTimer?.cancel();
    _requestId++;
    _settingsSubscription?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Use the Taipei calendar date even if the device time zone is changed.
    final taipeiDate = _now.toUtc().add(const Duration(hours: 8));
    final quote = pickDailyQuote(
      date: taipeiDate,
      seed: widget.hostUid,
      library: builtInQuotes,
      pendingFamily: widget.pendingFamily,
    );
    final report = _reportIsCurrent(_now) ? _report : null;
    return SafeArea(
      child: SingleChildScrollView(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!widget.showWeatherAndQuote && widget.api != null)
                    HostCarePanel(api: widget.api!, clock: () => _now),
                  if (widget.showWeatherAndQuote) ...[
                    SizedBox(
                      height: 72,
                      child: FilledButton.icon(
                        onPressed: _startingSpeech ? null : _readToday,
                        icon: const Icon(Icons.volume_up_outlined, size: 30),
                        label: Text(
                          _startingSpeech ? '準備朗讀…' : '聽今天',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                      ),
                    ),
                    if (_speechStatus != null)
                      Semantics(
                        liveRegion: true,
                        child: FhStatusBanner(message: _speechStatus!),
                      ),
                    const SizedBox(height: 20),
                    Text(
                      '今日天氣',
                      style: Theme.of(
                        context,
                      ).textTheme.titleLarge?.copyWith(color: FhColors.brand),
                    ),
                    const SizedBox(height: 12),
                    if (report == null)
                      FhStatusBanner(
                        tone:
                            _weatherStatus.contains('失敗') ||
                                _weatherStatus.contains('無法')
                            ? FhTone.danger
                            : FhTone.info,
                        message: _report != null
                            ? '天氣資料已過期，等待更新；每日一句照常顯示'
                            : _weatherStatus,
                      )
                    else ...[
                      Text(
                        '${report.city}：${report.temperatureC.round()} 度，${report.condition}',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '最高約 ${report.highC.round()} 度，最低約 ${report.lowC.round()} 度'
                        '${report.peakRainChance == null ? '' : '；今天最高降雨機率 ${report.peakRainChance}%'}',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      Text(
                        'Open-Meteo 預報｜更新 ${friendlyTime(report.observedAtUtc.millisecondsSinceEpoch, now: _now, taipei: true)}。請以實際天氣為準。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    if (_city != null &&
                        report == null &&
                        _weatherStatus != '正在確認今日天氣…')
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () => _fetchWeather(_city!),
                          child: const Text('重試天氣'),
                        ),
                      ),
                    if (widget.api != null &&
                        _weatherStatus.startsWith('天氣設定暫時無法讀取'))
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: _retrySettings,
                          child: const Text('重試讀取設定'),
                        ),
                      ),
                    const SizedBox(height: 20),
                    Text(
                      '每日一句',
                      style: Theme.of(
                        context,
                      ).textTheme.titleLarge?.copyWith(color: FhColors.brand),
                    ),
                    const SizedBox(height: 16),
                    Semantics(
                      label: '今天的每日一句：${quote.text}',
                      child: Text(
                        quote.text,
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                    ),
                    if (quote.source == DailyQuoteSource.family &&
                        quote.author != null)
                      Text(
                        '來自 ${quote.author}',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    if (widget.api != null)
                      HostCarePanel(api: widget.api!, clock: () => _now),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
