// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:flutter/material.dart';

import '../common/firebase_service.dart';
import '../common/ui/fh_format.dart';
import '../common/ui/fh_widgets.dart';

/// Recent leave/arrive events, readable only while grandma's consent is on.
class ClientPlacePanel extends StatefulWidget {
  final FirebaseService api;
  final String hostId;
  const ClientPlacePanel({super.key, required this.api, required this.hostId});

  @override
  State<ClientPlacePanel> createState() => _ClientPlacePanelState();
}

class _ClientPlacePanelState extends State<ClientPlacePanel> {
  Map<String, dynamic> consent = const {}, events = const {};
  StreamSubscription<Map<String, dynamic>>? consentSub, eventSub;

  bool get on =>
      consent['enabled'] == true &&
      consent['status'] == 'enabled' &&
      consent['disclosureVersion'] == 1;

  @override
  void initState() {
    super.initState();
    try {
      consentSub = widget.api
          .watch('care/${widget.hostId}/places/consent')
          .listen((v) {
            setState(() => consent = v);
            _bind();
          }, onError: (_) {});
    } catch (_) {}
  }

  void _bind() {
    eventSub?.cancel();
    eventSub = null;
    if (!on) {
      setState(() => events = const {});
      return;
    }
    try {
      eventSub = widget.api
          .watch('care/${widget.hostId}/places/events')
          .listen((v) => setState(() => events = v), onError: (_) {});
    } catch (_) {}
  }

  @override
  void dispose() {
    consentSub?.cancel();
    eventSub?.cancel();
    super.dispose();
  }

  bool showAll = false;

  String _clock(Object ms) {
    return friendlyTime(ms, taipei: true);
  }

  /// Event time first; a late upload also shows when it actually arrived.
  String _line(Map<String, dynamic> e) {
    final where = e['place'] == 'home'
        ? '家'
        : (consent['workName'] as String? ?? '工作地點');
    final act = e['transition'] == 'enter' ? '到' : '離開';
    final late =
        e['receivedAt'] is num &&
        (e['receivedAt'] as num) - (e['at'] as num) > 5 * 60_000;
    return '${_clock(e['at'] as num)} $act$where${late ? '（${_clock(e['receivedAt'] as num)} 才收到）' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final rows = events.values.map(asMap).where((e) => e['at'] is num).toList()
      ..sort((a, b) => (b['at'] as num).compareTo(a['at'] as num));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('長輩出門到家', style: Theme.of(context).textTheme.titleLarge),
        if (!on)
          FhEmptyState(
            icon: Icons.place_outlined,
            title: consent['status'] == 'paused'
                ? '長輩已暫停出門到家通知'
                : '尚未開啟。請在長輩手機「家人設定 → 出門到家通知」陪長輩一起設定。',
          )
        else if (rows.isEmpty)
          const FhEmptyState(icon: Icons.history, title: '目前還沒有紀錄')
        else ...[
          Text(
            '最近一次：${_line(rows.first)}',
            key: const Key('place-latest'),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (rows.length > 1)
            TextButton(
              onPressed: () => setState(() => showAll = !showAll),
              child: Text(showAll ? '收起紀錄' : '查看紀錄'),
            ),
          if (showAll)
            for (final e in rows.skip(1).take(20))
              Text(_line(e), style: Theme.of(context).textTheme.bodyMedium),
        ],
        Text(
          '這是長輩手機回報的到達／離開時間，不代表長輩現在的位置；手機省電或沒網路時可能晚到。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
