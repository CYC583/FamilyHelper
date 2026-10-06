// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:flutter/material.dart';

import '../common/care_companion.dart';
import '../common/family_messages_panel.dart';
import '../common/firebase_service.dart';
import 'client_weather_settings_page.dart';
import '../common/ui/fh_tokens.dart';
import '../common/ui/fh_widgets.dart';

/// Family "陪伴" tab: messages, what grandma pressed today, a plain weekly
/// summary and the schedule settings. Unshared items say so explicitly.
class ClientCompanionPage extends StatefulWidget {
  final FirebaseService api;
  final String hostId;
  final Map<String, dynamic> family;
  final DateTime Function() clock;
  final VoicePort voice;

  /// Inside the status tab: no chat (it has its own tab), no settings link,
  /// laid out as a plain column for an outer scroll view.
  final bool embedded;
  const ClientCompanionPage({
    super.key,
    required this.api,
    required this.hostId,
    required this.family,
    this.clock = DateTime.now,
    this.voice = const NativeVoicePort(),
    this.embedded = false,
  });

  @override
  State<ClientCompanionPage> createState() => _ClientCompanionPageState();
}

class _ClientCompanionPageState extends State<ClientCompanionPage> {
  final subs = <StreamSubscription<Map<String, dynamic>>>[];
  StreamSubscription<Map<String, dynamic>>? todaySub, soundSub;
  Map<String, dynamic> consent = const {}, today = const {};
  Map<String, dynamic> planV1 = const {}, planV2 = const {};
  Map<String, dynamic> statusSync = const {}, statusToday = const {};
  Map<String, dynamic> get plan => planV2.isNotEmpty ? planV2 : planV1;
  Map<String, dynamic> sound = const {};
  WeeklySummary? week;
  String? weekError, loadError;
  bool loadingWeek = false;
  int? listenedVersion;

  String get host => widget.hostId;
  Map<String, bool> get items =>
      asMap(consent['items']).map((k, v) => MapEntry(k, v == true));
  bool get sharing =>
      consent['enabled'] == true &&
      consent['status'] == 'enabled' &&
      consent['disclosureVersion'] == 1;

  @override
  void initState() {
    super.initState();
    _listen('care/$host/companion/consent', (value) {
      setState(() => consent = value);
      _rebindShared();
    });
    _listen('care/$host/settings/reminders', (v) => setState(() => planV1 = v));
    _listen(
      'care/$host/settings/reminderPlan',
      (v) => setState(() => planV2 = v),
    );
    _listen(
      'care/$host/reminderStatus/sync',
      (v) => setState(() => statusSync = v),
    );
    _listen(
      'care/$host/reminderStatus/days/${taipeiDateKey(widget.clock())}',
      (v) => setState(() => statusToday = v),
    );
  }

  void _listen(String path, void Function(Map<String, dynamic>) onData) {
    try {
      subs.add(
        widget.api
            .watch(path)
            .listen(
              onData,
              onError: (Object e) =>
                  setState(() => loadError = errorMessage(e)),
            ),
      );
    } catch (e) {
      loadError = errorMessage(e);
    }
  }

  /// Per-item reads only while that item is shared; hide cached values at once.
  void _rebindShared() {
    final version = (consent['version'] as num?)?.toInt();
    todaySub?.cancel();
    soundSub?.cancel();
    todaySub = soundSub = null;
    today = const {};
    sound = const {};
    if (!sharing) {
      listenedVersion = null;
      week = null;
      return;
    }
    if (items['responses'] == true) {
      try {
        todaySub = widget.api
            .watch(
              'care/$host/companion/responses/${taipeiDateKey(widget.clock())}',
            )
            .listen((v) => setState(() => today = v), onError: (_) {});
      } catch (_) {}
    }
    if (items['sound'] == true) {
      try {
        soundSub = widget.api
            .watch('care/$host/companion/sound/latest')
            .listen((v) => setState(() => sound = v), onError: (_) {});
      } catch (_) {}
    }
    if (listenedVersion != version) {
      listenedVersion = version;
      unawaited(loadWeek());
    }
  }

  Map<String, String> _rows(Map<String, dynamic> raw) => {
    for (final row in raw.values.map(asMap))
      if (row['type'] is String && row['time'] is String)
        '${row['type']}:${row['time']}': '${row['response']}',
  };

  Future<void> loadWeek() async {
    setState(() {
      loadingWeek = true;
      weekError = null;
    });
    try {
      final dates = weekDates(widget.clock());
      final responses = <String, Map<String, String>>{};
      final moods = <String, String>{};
      for (final date in dates) {
        if (items['responses'] == true) {
          responses[date] = _rows(
            await widget.api.read('care/$host/companion/responses/$date'),
          );
        }
        if (items['mood'] == true) {
          final mood = (await widget.api.read(
            'care/$host/companion/mood/$date',
          ))['mood'];
          if (mood is String) moods[date] = mood;
        }
      }
      var photoDays = <String>[];
      if (asMap(widget.family['photoConsent'])['enabled'] == true) {
        try {
          final list = await widget.api.call('listCarePhotos', {
            'hostId': host,
          });
          photoDays = [
            for (final p in (list['photos'] as List? ?? const []).map(asMap))
              if (p['day'] is String) p['day'] as String,
          ];
        } catch (_) {}
      }
      if (!mounted) return;
      setState(
        () => week = buildWeeklySummary(
          now: widget.clock(),
          responsesByDate: responses,
          moodByDate: moods,
          photoDays: photoDays,
          repliesShared: items['responses'] == true,
          moodShared: items['mood'] == true,
        ),
      );
    } catch (e) {
      if (mounted) setState(() => weekError = '本週摘要無法讀取：${errorMessage(e)}');
    } finally {
      if (mounted) setState(() => loadingWeek = false);
    }
  }

  @override
  void dispose() {
    for (final s in subs) {
      s.cancel();
    }
    todaySub?.cancel();
    soundSub?.cancel();
    super.dispose();
  }

  String _ringer(Map<String, dynamic> s) => [
    s['ringer'] == 'silent'
        ? '鈴聲靜音'
        : s['ringer'] == 'vibrate'
        ? '鈴聲震動'
        : '鈴聲開啟',
    if (s['dnd'] == true) '勿擾模式開著',
    if (s['mediaZero'] == true) '媒體音量為零',
  ].join('、');

  @override
  Widget build(BuildContext context) {
    final heading = Theme.of(context).textTheme.titleLarge;
    final names = {
      for (final e in asMap(widget.family['members']).entries)
        e.key: (asMap(e.value)['name'] as String?) ?? '家人',
    };
    final reminders = CareReminder.parsePlan(plan['items']);
    final now = widget.clock();
    final todayKey = taipeiDateKey(now);
    final children = <Widget>[
      if (loadError != null)
        FhStatusBanner(tone: FhTone.danger, message: '部分資料無法讀取：$loadError'),
      if (!widget.embedded) ...[
        Text('家人留言', style: heading),
        const SizedBox(height: 8),
        FamilyMessagesPanel(
          api: widget.api,
          hostId: host,
          selfUid: widget.api.uid,
          isHost: false,
          names: names,
          voice: widget.voice,
        ),
        const Divider(height: 32),
      ],
      Text('今天的提醒', style: heading),
      if (reminders.where((r) => r.occursOn(todayKey)).isEmpty)
        const FhEmptyState(icon: Icons.alarm_off_outlined, title: '今天沒有提醒')
      else
        for (final item in reminders.where((r) => r.occursOn(todayKey)))
          ListTile(
            key: Key('client-reminder-${item.deliveryKey(todayKey)}'),
            contentPadding: EdgeInsets.zero,
            title: Text(
              '${item.time} ${item.text.isNotEmpty ? item.text : item.title}',
            ),
            subtitle: Text(
              familyReminderStatus(
                item: item,
                today: todayKey,
                now: now,
                planVersion: (plan['version'] as num?)?.toInt() ?? 0,
                syncedVersion: (statusSync['version'] as num?)?.toInt(),
                delivery: () {
                  final d = asMap(
                    statusToday[(item.id.isNotEmpty
                            ? item.id
                            : '${item.type}:${item.time}')
                        .replaceAll(':', '_')],
                  );
                  return d.isEmpty ? null : d;
                }(),
              ),
            ),
          ),
      Text(
        '「已播放」只代表長輩手機播出了，不代表長輩聽到或做了。',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      if (sharing && items['sound'] == true) ...[
        const Divider(height: 32),
        Text('長輩手機聲音', style: heading),
        if (sound.isEmpty)
          const FhEmptyState(icon: Icons.volume_off_outlined, title: '尚未收到聲音狀態')
        else
          Text(_ringer(sound)),
        Text(
          '手機靜音或勿擾超過一小時會通知家人；請直接打電話確認。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
      const Divider(height: 32),
      Row(
        children: [
          Expanded(child: Text('本週摘要（週一到今天）', style: heading)),
          IconButton(
            tooltip: '重新整理摘要',
            onPressed: loadingWeek || !sharing ? null : loadWeek,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      if (!sharing)
        const FhEmptyState(
          icon: Icons.insights_outlined,
          title: '尚無完整摘要',
          message: '長輩沒有分享提醒回覆或心情，摘要只能顯示照片。',
        )
      else if (loadingWeek)
        const FhStatusBanner(message: '正在整理…')
      else if (weekError != null)
        FhStatusBanner(tone: FhTone.danger, message: weekError!)
      else if (week != null)
        for (final line in week!.lines()) Text('・$line'),
      Text(
        '摘要只列出長輩按過什麼，不代表健康狀況，也不判斷有沒有吃藥。',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      if (!widget.embedded) const Divider(height: 32),
      if (!widget.embedded)
        OutlinedButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                appBar: AppBar(title: const Text('早安天氣與提醒設定')),
                body: ClientWeatherSettingsPage(api: widget.api, hostId: host),
              ),
            ),
          ),
          icon: const Icon(Icons.schedule),
          label: const Text('早安天氣與提醒設定'),
        ),
    ];
    return widget.embedded
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          )
        : ListView(padding: const EdgeInsets.all(20), children: children);
  }
}
