// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:flutter/material.dart';

import '../common/care_companion.dart';
import '../common/firebase_service.dart';
import 'battery_guardian_panel.dart';
import 'client_companion_page.dart';
import 'client_place_panel.dart';
import 'client_app_usage_page.dart';
import '../common/ui/fh_tokens.dart';
import '../common/ui/fh_format.dart';

/// Short one-line answers to "how is grandma's phone?" Each row opens the
/// full panel. Rows only report what was actually received, with no guessing.
class ClientStatusSummary extends StatefulWidget {
  final FirebaseService api;
  final String hostId;
  final Map<String, dynamic> family;
  final DateTime Function() clock;
  const ClientStatusSummary({
    super.key,
    required this.api,
    required this.hostId,
    required this.family,
    this.clock = DateTime.now,
  });

  @override
  State<ClientStatusSummary> createState() => _ClientStatusSummaryState();
}

class _ClientStatusSummaryState extends State<ClientStatusSummary> {
  Map<String, dynamic> battery = const {},
      places = const {},
      placeConsent = const {},
      sound = const {},
      reminders = const {},
      usageConsent = const {},
      usageToday = const {};
  final subs = <StreamSubscription<Map<String, dynamic>>>[];

  final retries = <Timer>[];

  @override
  void initState() {
    super.initState();
    final today = taipeiDateKey(widget.clock());
    for (final (path, set) in [
      ('battery/latest', (Map<String, dynamic> v) => battery = v),
      ('places/consent', (Map<String, dynamic> v) => placeConsent = v),
      ('places/events', (Map<String, dynamic> v) => places = v),
      ('companion/sound/latest', (Map<String, dynamic> v) => sound = v),
      ('reminderStatus/days/$today', (Map<String, dynamic> v) => reminders = v),
      ('appUsage/consent', (Map<String, dynamic> v) => usageConsent = v),
      ('appUsage/days/$today', (Map<String, dynamic> v) => usageToday = v),
    ]) {
      _listen(path, set);
    }
  }

  /// Items grandma has not shared yet are denied by the database; try again
  /// later so a row fills in once she turns sharing on.
  void _listen(String path, void Function(Map<String, dynamic>) set) {
    try {
      subs.add(
        widget.api
            .watch('care/${widget.hostId}/$path')
            .listen(
              (v) => setState(() => set(v)),
              onError: (_) {
                if (!mounted) return;
                retries.add(
                  Timer(const Duration(minutes: 1), () {
                    if (mounted) _listen(path, set);
                  }),
                );
              },
            ),
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    for (final s in subs) {
      s.cancel();
    }
    for (final t in retries) {
      t.cancel();
    }
    super.dispose();
  }

  String _clock(num ms) {
    return friendlyTime(ms, now: widget.clock(), taipei: true);
  }

  String get batteryLine {
    final p = battery['batteryPercent'];
    if (p is! num) return '尚未分享電量';
    final at = battery['observedAt'];
    return '${p.toInt()}%${battery['charging'] == true ? '・充電中' : ''}${at is num ? '（${_clock(at)}）' : ''}';
  }

  String get placeLine {
    if (placeConsent['enabled'] != true) {
      return placeConsent['status'] == 'paused' ? '長輩已暫停' : '尚未開啟';
    }
    final rows = places.values.map(asMap).where((e) => e['at'] is num).toList()
      ..sort((a, b) => (b['at'] as num).compareTo(a['at'] as num));
    if (rows.isEmpty) return '還沒有紀錄';
    final e = rows.first;
    final where = e['place'] == 'home'
        ? '家'
        : (placeConsent['workName'] as String? ?? '工作地點');
    return '${_clock(e['at'] as num)} ${e['transition'] == 'enter' ? '到' : '離開'}$where';
  }

  String get reminderLine {
    final states = reminders.values.map((v) => asMap(v)['state']).toList();
    if (states.isEmpty) return '今天還沒有播放紀錄';
    final played = states
        .where((s) => s == 'played' || s == 'text_fallback')
        .length;
    final problems = states.length - played;
    return '今天已播 $played 個${problems > 0 ? '・$problems 個可能沒聲音' : ''}';
  }

  String get usageLine {
    if (usageConsent['enabled'] != true) {
      return usageConsent['status'] == 'paused' ? '長輩已暫停' : '尚未開啟';
    }
    final total = (usageToday['total'] as num?)?.toInt();
    if (total == null) return '今天還沒有紀錄';
    final apps = usageToday['apps'];
    final top = apps is List && apps.isNotEmpty && apps.first is Map
        ? '・最多：${(apps.first as Map)['name']}'
        : '';
    return '今天 ${usageMinutes(total)}$top';
  }

  bool get soundProblem =>
      sound['ringer'] == 'silent' ||
      sound['dnd'] == true ||
      sound['mediaZero'] == true;

  String get soundLine => sound.isEmpty
      ? '尚未分享'
      : soundProblem
      ? [
          if (sound['ringer'] == 'silent') '鈴聲靜音',
          if (sound['dnd'] == true) '勿擾模式開著',
          if (sound['mediaZero'] == true) '媒體音量為零',
        ].join('、')
      : '正常';

  void _open(String title, Widget child) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: ListView(padding: const EdgeInsets.all(20), children: [child]),
      ),
    ),
  );

  Widget _row(
    String key,
    IconData icon,
    String title,
    String line,
    VoidCallback onTap, {
    bool warn = false,
  }) => Card(
    child: ListTile(
      key: Key('status-$key'),
      minVerticalPadding: 14,
      leading: Icon(
        icon,
        size: 32,
        color: warn ? FhColors.danger : FhColors.brand,
      ),
      title: Text(title, style: Theme.of(context).textTheme.titleMedium),
      subtitle: Text(
        line,
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: warn ? FhColors.danger : null),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final host = widget.hostId;
    final low =
        battery['batteryPercent'] is num &&
        (battery['batteryPercent'] as num) <= 20 &&
        battery['charging'] != true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _row(
          'battery',
          Icons.battery_std,
          '電量',
          batteryLine,
          () => _open(
            '電量守護',
            BatteryGuardianPanel(api: widget.api, hostId: host),
          ),
          warn: low,
        ),
        _row(
          'place',
          Icons.home_outlined,
          '出門到家',
          placeLine,
          () => _open('出門到家', ClientPlacePanel(api: widget.api, hostId: host)),
        ),
        _row(
          'reminders',
          Icons.alarm,
          '提醒',
          reminderLine,
          () => _open(
            '提醒與心情',
            ClientCompanionPage(
              api: widget.api,
              hostId: host,
              family: widget.family,
              embedded: true,
            ),
          ),
        ),
        _row(
          'sound',
          Icons.volume_up_outlined,
          '手機聲音',
          soundLine,
          () => _open(
            '提醒與心情',
            ClientCompanionPage(
              api: widget.api,
              hostId: host,
              family: widget.family,
              embedded: true,
            ),
          ),
          warn: soundProblem,
        ),
        _row(
          'usage',
          Icons.phone_android,
          '手機使用時間',
          usageLine,
          () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ClientAppUsagePage(
                api: widget.api,
                hostId: host,
                hostName: widget.family['name'] as String? ?? '長輩',
              ),
            ),
          ),
        ),
      ],
    );
  }
}
