// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:flutter/material.dart';

import '../common/care_companion.dart';
import '../common/firebase_service.dart';
import '../common/ui/fh_tokens.dart';
import '../common/ui/fh_format.dart';
import '../common/ui/fh_widgets.dart';

String usageMinutes(int m) =>
    m < 60 ? '$m 分鐘' : '${m ~/ 60} 小時${m % 60 == 0 ? '' : ' ${m % 60} 分'}';

/// Minutes per app on grandma's phone, today and the last 7 days. Only
/// shown while grandma has app-usage sharing on; names and minutes only.
class ClientAppUsagePage extends StatefulWidget {
  final FirebaseService api;
  final String hostId;
  final String hostName;
  final DateTime Function() clock;
  const ClientAppUsagePage({
    super.key,
    required this.api,
    required this.hostId,
    this.hostName = '長輩',
    this.clock = DateTime.now,
  });

  @override
  State<ClientAppUsagePage> createState() => _ClientAppUsagePageState();
}

class _ClientAppUsagePageState extends State<ClientAppUsagePage> {
  Map<String, dynamic> consent = const {}, day = const {};
  bool consentLoaded = false, busy = false;
  String? status;
  late String selected = taipeiDateKey(widget.clock());
  StreamSubscription<Map<String, dynamic>>? consentSub, daySub;

  bool get on => consent['enabled'] == true && consent['status'] == 'enabled';

  List<String> get days {
    final wall = widget.clock().toUtc().add(const Duration(hours: 8));
    return [
      for (var i = 0; i < 7; i++)
        DateTime.utc(
          wall.year,
          wall.month,
          wall.day,
        ).subtract(Duration(days: i)).toIso8601String().substring(0, 10),
    ];
  }

  @override
  void initState() {
    super.initState();
    try {
      consentSub = widget.api
          .watch('care/${widget.hostId}/appUsage/consent')
          .listen((v) {
            final was = on;
            setState(() {
              consent = v;
              consentLoaded = true;
            });
            if (on && !was) _watchDay();
            if (!on) {
              daySub?.cancel();
              setState(() => day = const {});
            }
          }, onError: (_) => setState(() => consentLoaded = true));
    } catch (_) {
      consentLoaded = true;
    }
  }

  void _watchDay() {
    daySub?.cancel();
    setState(() => day = const {});
    try {
      daySub = widget.api
          .watch('care/${widget.hostId}/appUsage/days/$selected')
          .listen((v) => setState(() => day = v), onError: (_) {});
    } catch (_) {}
  }

  @override
  void dispose() {
    consentSub?.cancel();
    daySub?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    setState(() {
      busy = true;
      status = null;
    });
    try {
      await widget.api.call('requestHostUpdate', {
        'hostId': widget.hostId,
        'kind': 'usage',
      });
      if (mounted) {
        setState(() => status = '已請${widget.hostName}的手機更新，約半分鐘內會更新');
      }
    } catch (e) {
      if (mounted) setState(() => status = errorMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String _label(String key) {
    final today = days.first;
    if (key == today) return '今天';
    if (key == days[1]) return '昨天';
    final d = DateTime.parse(key);
    return '${d.month}/${d.day}';
  }

  @override
  Widget build(BuildContext context) {
    final apps = [
      for (final a in (day['apps'] as List? ?? const []))
        if (a is Map && a['name'] is String && a['minutes'] is num)
          (a['name'] as String, (a['minutes'] as num).toInt()),
    ];
    final most = apps.isEmpty ? 1 : apps.first.$2;
    return Scaffold(
      appBar: AppBar(title: Text('${widget.hostName}的手機使用時間')),
      body: !consentLoaded
          ? const FhLoadingView(label: '正在讀取使用時間分享狀態…')
          : !on
          ? FhEmptyState(
              icon: Icons.hourglass_empty,
              title: consent['status'] == 'paused'
                  ? '${widget.hostName}已暫停使用時間分享'
                  : '${widget.hostName}還沒有開啟使用時間分享。\n請在${widget.hostName}的手機「家人設定 → 分享手機使用時間」陪長輩一起開啟。',
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final d in days)
                      ChoiceChip(
                        key: Key('usage-day-$d'),
                        label: Text(_label(d)),
                        selected: selected == d,
                        onSelected: (_) {
                          setState(() => selected = d);
                          _watchDay();
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (apps.isEmpty)
                  FhEmptyState(
                    icon: Icons.bar_chart_outlined,
                    title: selected == days.first
                        ? '今天還沒有紀錄（${widget.hostName}的手機約每 30 分鐘更新一次）'
                        : '這天沒有紀錄',
                  )
                else ...[
                  Text(
                    '合計 ${usageMinutes((day['total'] as num?)?.toInt() ?? 0)}',
                    key: const Key('usage-total'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  if (day['updatedAt'] is num)
                    Text(
                      '更新於 ${_clock((day['updatedAt'] as num).toInt())}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  const SizedBox(height: 12),
                  for (final (name, minutes) in apps)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  name,
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ),
                              Text(
                                usageMinutes(minutes),
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          LinearProgressIndicator(
                            value: minutes / most,
                            minHeight: 8,
                            borderRadius: BorderRadius.circular(4),
                            color: FhColors.brand,
                            backgroundColor: FhColors.brandTint,
                          ),
                        ],
                      ),
                    ),
                ],
                if (selected == days.first)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: OutlinedButton.icon(
                      key: const Key('usage-refresh'),
                      onPressed: busy ? null : refresh,
                      icon: const Icon(Icons.refresh),
                      label: const Text('現在更新'),
                    ),
                  ),
                if (status != null) FhStatusBanner(message: status!),
                const SizedBox(height: 12),
                Text(
                  '只顯示有桌面圖示的 App 和分鐘數，看不到 App 裡的內容。數字由手機系統統計，可能和實際略有差異。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
    );
  }

  String _clock(int ms) {
    return friendlyTime(ms, now: widget.clock(), taipei: true);
  }
}
