// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:flutter/material.dart';

import '../common/firebase_service.dart';
import '../common/native_bridge.dart';
import 'remote_view_page.dart';
import '../common/ui/fh_tokens.dart';
import '../common/ui/fh_format.dart';
import '../common/ui/fh_widgets.dart';

/// Full-screen alert for SOS or 呼叫 from grandma, read aloud repeatedly.
/// "接聽" answers the call she started (first family member wins).
class IncomingAlertPage extends StatefulWidget {
  final FirebaseService api;
  final String hostId;
  final String alertId;
  final Map<String, dynamic> alert;
  final Future<void> Function(String text) speak;
  const IncomingAlertPage({
    super.key,
    required this.api,
    required this.hostId,
    required this.alertId,
    required this.alert,
    this.speak = NativeBridge.speakText,
  });

  @override
  State<IncomingAlertPage> createState() => _IncomingAlertPageState();
}

class _IncomingAlertPageState extends State<IncomingAlertPage> {
  Timer? _repeat, _closeLater;
  StreamSubscription<Map<String, dynamic>>? _alertSub;
  String? _answeredBy;
  bool _cancelled = false;
  bool _busy = false;
  String? _error;
  bool get _sos => widget.alert['type'] == 'sos';
  String? get _session => widget.alert['sessionId'] as String?;

  @override
  void initState() {
    super.initState();
    _announce();
    _repeat = Timer.periodic(const Duration(seconds: 8), (t) {
      if (t.tick >= 6) t.cancel();
      _announce();
    });
    _watchAnswer(widget.alert);
    try {
      _alertSub = widget.api
          .watch('core/families/${widget.hostId}/alerts/${widget.alertId}')
          .listen(_watchAnswer, onError: (_) {});
    } catch (_) {}
  }

  /// Another family member answered first: stop ringing and say who.
  void _watchAnswer(Map<String, dynamic> alert) {
    if (alert['cancelledAt'] is num && !_cancelled && _answeredBy == null) {
      _repeat?.cancel();
      if (!mounted) return;
      setState(() => _cancelled = true);
      unawaited(widget.speak('長輩取消了這次呼叫').catchError((_) {}));
      _closeLater = Timer(const Duration(seconds: 5), () {
        if (mounted) Navigator.of(context).maybePop();
      });
      return;
    }
    final by = asMap(alert['answeredBy']);
    final uid = by['uid'];
    if (uid is! String || _answeredBy != null || _busy) return;
    String me;
    try {
      me = widget.api.uid;
    } catch (_) {
      me = '';
    }
    if (uid == me) return;
    _repeat?.cancel();
    final name = by['name'] as String? ?? '其他家人';
    if (!mounted) return;
    setState(() => _answeredBy = name);
    unawaited(widget.speak('$name 已經接聽了').catchError((_) {}));
    _closeLater = Timer(const Duration(seconds: 5), () {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  void _announce() => unawaited(
    widget
        .speak(_sos ? '緊急通知！長輩按了緊急求助，請馬上接聽。' : '長輩找你，請接聽。')
        .catchError((_) {}),
  );

  @override
  void dispose() {
    _repeat?.cancel();
    _closeLater?.cancel();
    _alertSub?.cancel();
    super.dispose();
  }

  String _clock(Object? ms) {
    return friendlyTime(ms, taipei: true);
  }

  Future<void> _ack() async {
    try {
      await widget.api.call('acknowledgeAlert', {
        'hostId': widget.hostId,
        'alertId': widget.alertId,
      });
    } catch (_) {}
  }

  Future<void> _answer() async {
    final id = _session;
    if (id == null) return;
    _repeat?.cancel();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final answer = await widget.api.call('answerHostCall', {'sessionId': id});
      unawaited(_ack());
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => RemoteViewPage(
            api: widget.api,
            id: id,
            shareScreen: answer['shareScreen'] != false,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = errorMessage(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _sos ? FhColors.danger : FhColors.brand;
    final loc = asMap(widget.alert['location']);
    return Scaffold(
      backgroundColor: color,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Icon(
                _sos ? Icons.emergency : Icons.video_call,
                size: 96,
                color: Colors.white,
              ),
              const SizedBox(height: 16),
              Text(
                _sos ? '長輩按了緊急求助' : '長輩找你',
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.headlineMedium?.copyWith(color: Colors.white),
              ),
              const SizedBox(height: 12),
              Text(
                _sos ? '請馬上接聽；也可以直接打電話給長輩。' : '接聽後可以和長輩通話，並看到長輩的手機畫面。',
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(color: Colors.white),
              ),
              if (_sos && loc['lat'] is num && loc['lng'] is num) ...[
                const SizedBox(height: 12),
                SizedBox(
                  height: 56,
                  child: OutlinedButton.icon(
                    key: const Key('incoming-map'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white, width: 2),
                    ),
                    onPressed: () => NativeBridge.openMap(
                      (loc['lat'] as num).toDouble(),
                      (loc['lng'] as num).toDouble(),
                    ),
                    icon: const Icon(Icons.map),
                    label: Text(
                      '開啟地圖',
                      style: Theme.of(
                        context,
                      ).textTheme.labelLarge?.copyWith(color: Colors.white),
                    ),
                  ),
                ),
                Text(
                  '位置取得時間 ${_clock(loc['time'])}・誤差約 ${(loc['accuracy'] as num?)?.round() ?? '?'} 公尺',
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.white),
                ),
              ] else if (_sos) ...[
                const SizedBox(height: 8),
                Text(
                  '這次沒有取得長輩的位置',
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.white),
                ),
              ],
              if (_cancelled) ...[
                const SizedBox(height: 20),
                Container(
                  key: const Key('incoming-cancelled'),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    '長輩取消了這次呼叫',
                    textAlign: TextAlign.center,
                    style: Theme.of(
                      context,
                    ).textTheme.headlineSmall?.copyWith(color: color),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                FhStatusBanner(tone: FhTone.danger, message: _error!),
              ],
              if (_answeredBy != null) ...[
                const SizedBox(height: 20),
                Container(
                  key: const Key('incoming-answered-by'),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    '$_answeredBy 已搶先接聽',
                    textAlign: TextAlign.center,
                    style: Theme.of(
                      context,
                    ).textTheme.headlineSmall?.copyWith(color: color),
                  ),
                ),
              ],
              const Spacer(),
              if (_session != null && _answeredBy == null && !_cancelled)
                SizedBox(
                  height: 96,
                  child: FilledButton.icon(
                    key: const Key('incoming-answer'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: color,
                    ),
                    onPressed: _busy ? null : _answer,
                    icon: const Icon(Icons.call, size: 40),
                    label: Text(
                      _busy ? '接通中…' : '接聽',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              TextButton(
                key: const Key('incoming-dismiss'),
                onPressed: () async {
                  _repeat?.cancel();
                  await _ack();
                  if (context.mounted) Navigator.of(context).pop();
                },
                child: Text(
                  '我知道了（關閉）',
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
