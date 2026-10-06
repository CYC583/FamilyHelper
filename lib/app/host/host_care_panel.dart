// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:flutter/material.dart';

import '../common/care_companion.dart';
import '../common/daily_quote.dart';
import '../common/daily_quote_library.dart';
import '../common/firebase_service.dart';
import '../common/native_bridge.dart';
import 'host_care_settings_page.dart';
import '../common/ui/fh_tokens.dart';
import '../common/ui/fh_widgets.dart';

/// Secondary "Today" content: reminder replies, mood and family messages.
/// The two primary help buttons stay on the home tab and never depend on this.
class HostCarePanel extends StatefulWidget {
  final FirebaseService api;
  final DateTime Function() clock;
  const HostCarePanel({
    super.key,
    required this.api,
    this.clock = DateTime.now,
  });

  @override
  State<HostCarePanel> createState() => _HostCarePanelState();
}

class _HostCarePanelState extends State<HostCarePanel>
    with WidgetsBindingObserver {
  Map<String, dynamic> snap = const {};
  Map<String, String> names = const {};
  Map<String, dynamic> consent = const {};
  final subs = <StreamSubscription<Map<String, dynamic>>>[];
  String? status;
  String? localMood;
  bool busy = false;
  Map<String, dynamic>? v1Plan, v2Plan;

  void _handOver() {
    final plan = (v2Plan?.isNotEmpty ?? false) ? v2Plan! : v1Plan;
    if (plan == null || plan.isEmpty) return;
    unawaited(
      NativeBridge.careSaveReminderPlan(
        uid,
        plan,
      ).then((saved) => saved ? runNow() : null).catchError((_) {}),
    );
  }

  String get uid => widget.api.uid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pushQuotes();
    _listen('core/families/$uid', (family) {
      final members = asMap(family['members']);
      setState(
        () => names = {
          for (final e in members.entries)
            e.key: (asMap(e.value)['name'] as String?) ?? '家人',
        },
      );
    });
    _listen('care/$uid/settings/weather', (weather) {
      unawaited(
        NativeBridge.careSaveWeather(
          weather.isEmpty ? null : weather,
        ).catchError((_) {}),
      );
    });
    // v2 plan (daily/once, voice) wins; the v1 daily list is the fallback.
    _listen('care/$uid/settings/reminderPlan', (plan) {
      v2Plan = plan;
      _handOver();
    });
    _listen('care/$uid/settings/reminders', (plan) {
      v1Plan = plan;
      _handOver();
    });
    _listen('care/$uid/voiceProfiles', (profiles) {
      unawaited(
        NativeBridge.careSaveVoiceProfiles(profiles).catchError((_) {}),
      );
    });
    _listen('care/$uid/companion/consent', (value) {
      setState(() => consent = value);
      unawaited(_mirrorConsent(value));
    });
    unawaited(runNow());
  }

  void _listen(String path, void Function(Map<String, dynamic>) onData) {
    try {
      subs.add(widget.api.watch(path).listen(onData, onError: (_) {}));
    } catch (_) {
      // Firebase unavailable: the local reminder list still works.
    }
  }

  /// The server copy is grandma's own decision; keep the phone in step so a
  /// reinstall or a pause on another screen takes effect here too.
  Future<void> _mirrorConsent(Map<String, dynamic> cloud) async {
    try {
      final local = (snap['companionVersion'] as num?)?.toInt() ?? 0;
      final version = (cloud['version'] as num?)?.toInt() ?? 0;
      final active = cloud['enabled'] == true && cloud['status'] == 'enabled';
      if (active && version != local) {
        await NativeBridge.careSetCompanion(
          uid,
          version,
          asMap(cloud['items']).map((k, v) => MapEntry(k, v == true)),
        );
      } else if (!active && local != 0) {
        await NativeBridge.careStopCompanion();
      }
      await refresh();
    } catch (_) {}
  }

  void _pushQuotes() {
    final now = widget.clock();
    final quotes = <String, String>{};
    for (var i = 0; i < 7; i++) {
      final wall = now.toUtc().add(Duration(hours: 8, days: i));
      quotes[taipeiDateKey(now.add(Duration(days: i)))] = pickDailyQuote(
        date: DateTime.utc(wall.year, wall.month, wall.day),
        seed: uid,
        library: builtInQuotes,
      ).text;
    }
    unawaited(NativeBridge.careSaveQuotes(quotes).catchError((_) {}));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _pushQuotes();
      unawaited(runNow());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final s in subs) {
      s.cancel();
    }
    super.dispose();
  }

  /// The next reminder first; ones already played or missed go below.
  List<CareReminder> _ordered(
    List<CareReminder> plan,
    String today,
    Map<String, String> deliveries,
  ) {
    final todays = plan.where((p) => p.occursOn(today)).toList();
    bool pending(CareReminder p) =>
        hostReminderStatus(
          deliveries[p.deliveryKey(today)],
          p,
          widget.clock(),
        ) ==
        '等等會提醒你';
    return [...todays.where(pending), ...todays.where((p) => !pending(p))];
  }

  Future<void> _replay(String key) async {
    setState(() => busy = true);
    try {
      await NativeBridge.careReplay(key);
    } catch (_) {
      if (mounted) setState(() => status = '現在無法播放，請稍後再試');
    } finally {
      if (mounted) setState(() => busy = false);
    }
    await refresh();
  }

  Future<void> runNow() async {
    try {
      await NativeBridge.careRunNow();
    } catch (_) {}
    await refresh();
  }

  Future<void> refresh() async {
    try {
      final value = await NativeBridge.careSnapshot();
      if (mounted) setState(() => snap = value);
    } catch (_) {
      if (mounted) setState(() => snap = const {'unavailable': true});
    }
  }

  Future<void> mood(String value) async {
    final shared = asMap(snap['companionItems'])['mood'] == true;
    setState(() {
      busy = true;
      localMood = value;
    });
    try {
      if (shared) {
        await widget.api.call('recordMood', {
          'date': taipeiDateKey(widget.clock()),
          'mood': value,
          'consentVersion': (snap['companionVersion'] as num?)?.toInt() ?? 0,
        });
        setState(() => status = '心情已分享給家人');
        unawaited(NativeBridge.speakText('收到了，已經告訴家人').catchError((_) {}));
      } else {
        setState(() => status = '已記下今天的心情');
        unawaited(NativeBridge.speakText('收到了').catchError((_) {}));
      }
    } catch (e) {
      setState(() => status = '心情沒有送出，請再按一次');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final heading = Theme.of(
      context,
    ).textTheme.titleLarge?.copyWith(color: FhColors.brand);
    final plan = CareReminder.parsePlan(snap['plan']);
    final today = taipeiDateKey(widget.clock());
    final deliveries = asMap(
      snap['deliveries'],
    ).map((k, v) => MapEntry(k, v.toString()));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('今天心情好嗎？', style: heading),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final (key, face, label) in const [
              ('good', '😄', '開心'),
              ('ok', '🙂', '還好'),
              ('tired', '😪', '有點累'),
              ('bad', '😢', '不太好'),
            ])
              Semantics(
                button: true,
                selected: localMood == key,
                label: label,
                child: InkWell(
                  key: Key('mood-$key'),
                  borderRadius: BorderRadius.circular(20),
                  onTap: busy ? null : () => mood(key),
                  child: Container(
                    width: 96,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: localMood == key
                          ? FhColors.brandSoft
                          : Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: localMood == key
                            ? FhColors.brand
                            : FhColors.outline,
                        width: localMood == key ? 3 : 1,
                      ),
                    ),
                    child: Column(
                      children: [
                        Text(face, style: const TextStyle(fontSize: 48)),
                        Text(
                          label,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 24),
        Text('今天的提醒', style: heading),
        const SizedBox(height: 8),
        if (snap['unavailable'] == true)
          const FhStatusBanner(tone: FhTone.danger, message: '提醒狀態暫時無法讀取')
        else if (snap['enabled'] == true &&
            (snap['disclosure'] as num? ?? 1) < 2)
          Card(
            color: FhColors.warningSoft,
            child: ListTile(
              title: Text(
                '提醒說明有更新',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              subtitle: Text(
                '請按這裡重新看一次並確認',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => HostCareSettingsPage(api: widget.api),
                  ),
                );
                refresh();
              },
            ),
          )
        else if (snap['enabled'] != true)
          Row(
            children: [
              Expanded(
                child: Text(
                  '提醒尚未開啟',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              TextButton(
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => HostCareSettingsPage(api: widget.api),
                    ),
                  );
                  refresh();
                },
                child: Text(
                  '去開啟',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            ],
          )
        else if (plan.where((p) => p.occursOn(today)).isEmpty)
          const FhEmptyState(icon: Icons.alarm_off_outlined, title: '今天沒有提醒')
        else
          for (final item in _ordered(plan, today, deliveries))
            Card(
              key: Key('host-reminder-${item.deliveryKey(today)}'),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: Row(
                  children: [
                    Icon(
                      item.voiceId != null
                          ? Icons.record_voice_over
                          : Icons.alarm,
                      size: 36,
                      color: FhColors.brand,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${item.time}  ${item.text.isNotEmpty ? item.text : item.title}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            '${item.author.isNotEmpty ? '${item.author}・' : ''}${hostReminderStatus(deliveries[item.deliveryKey(today)], item, widget.clock())}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    TextButton.icon(
                      key: Key('replay-${item.deliveryKey(today)}'),
                      onPressed: busy
                          ? null
                          : () => _replay(item.deliveryKey(today)),
                      icon: const Icon(Icons.replay, size: 28),
                      label: Text(
                        hostReminderStatus(
                                  deliveries[item.deliveryKey(today)],
                                  item,
                                  widget.clock(),
                                ) ==
                                '等等會提醒你'
                            ? '先聽聽看'
                            : '再聽一次',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        if (status != null)
          Semantics(liveRegion: true, child: FhStatusBanner(message: status!)),
        if (snap['reminderEvent'] is String)
          Text(
            '上次提醒：${snap['reminderEvent']}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        if (snap['morningResult'] is String)
          Text(
            '早安播報：${snap['morningResult']}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
      ],
    );
  }
}
