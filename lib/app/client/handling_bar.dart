// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:flutter/material.dart';

import '../common/firebase_service.dart';
import '../common/ui/fh_tokens.dart';
import '../common/ui/fh_widgets.dart';

/// "我來處理 / 需要其他人幫忙 / 已處理" for one event, shared by all family
/// phones. Separate from "我知道了" (seen) and from system facts such as
/// "battery recovered".
class HandlingBar extends StatefulWidget {
  final FirebaseService api;
  final String hostId;
  final String eventKey;
  final Stream<Map<String, dynamic>>? handling;
  const HandlingBar({
    super.key,
    required this.api,
    required this.hostId,
    required this.eventKey,
    this.handling,
  });

  @override
  State<HandlingBar> createState() => _HandlingBarState();
}

class _HandlingBarState extends State<HandlingBar> {
  static const quickNotes = ['已打電話給長輩', '已提醒充電', '已到長輩家', '長輩沒事'];
  Map<String, dynamic> current = const {};
  StreamSubscription<Map<String, dynamic>>? sub;
  bool busy = false;
  String? error;

  String get me {
    try {
      return widget.api.uid;
    } catch (_) {
      return '';
    }
  }

  @override
  void initState() {
    super.initState();
    try {
      sub =
          (widget.handling ??
                  widget.api.watch(
                    'care/${widget.hostId}/handling/${widget.eventKey}',
                  ))
              .listen((v) => setState(() => current = v), onError: (_) {});
    } catch (_) {}
  }

  @override
  void dispose() {
    sub?.cancel();
    super.dispose();
  }

  Future<void> act(String action, [String? note]) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.api.call('setHandling', {
        'hostId': widget.hostId,
        'eventKey': widget.eventKey,
        'action': action,
        if (note != null) 'note': note,
      });
    } catch (e) {
      if (mounted) setState(() => error = errorMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> resolve() async {
    final controller = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('處理結果'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 6,
              children: [
                for (final q in quickNotes)
                  ActionChip(
                    label: Text(q),
                    onPressed: () => Navigator.pop(ctx, q),
                  ),
              ],
            ),
            TextField(
              controller: controller,
              maxLength: 40,
              decoration: const InputDecoration(labelText: '或自己寫一句'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('完成'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (note != null) await act('resolve', note);
  }

  @override
  Widget build(BuildContext context) {
    final status = current['status'];
    final name = current['name'] as String? ?? '家人';
    final mine = current['by'] == me;
    final line = switch (status) {
      'claimed' => mine ? '你正在處理' : '$name 已接手處理',
      'open' => '$name 需要其他人幫忙',
      'resolved' => '已處理：${current['note'] ?? ''}（$name）',
      _ => '還沒有人接手',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          line,
          key: Key('handling-${widget.eventKey}'),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        if (status != 'resolved')
          Wrap(
            spacing: 8,
            children: [
              if (status != 'claimed' || !mine)
                OutlinedButton(
                  onPressed: busy || (status == 'claimed' && !mine)
                      ? null
                      : () => act('claim'),
                  child: const Text('我來處理'),
                ),
              if (status == 'claimed' && mine)
                OutlinedButton(
                  onPressed: busy ? null : () => act('release'),
                  child: const Text('需要其他人幫忙'),
                ),
              FilledButton.tonal(
                onPressed: busy ? null : resolve,
                child: const Text('已處理'),
              ),
            ],
          ),
        if (error != null) FhStatusBanner(tone: FhTone.danger, message: error!),
      ],
    );
  }
}
