// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:flutter/material.dart';

import '../common/family_messages_panel.dart';
import '../common/firebase_service.dart';
import '../common/ui/fh_tokens.dart';

/// "我的聲音": a short intro clip in your own voice ("阿嬤，我是小明").
/// Grandma's phone plays it before your reminders and text messages, and on
/// your day of the morning weather rotation. Only you can set yours.
class ClientVoiceProfilePage extends StatefulWidget {
  final FirebaseService api;
  final String hostId;
  final VoicePort voice;
  const ClientVoiceProfilePage({
    super.key,
    required this.api,
    required this.hostId,
    this.voice = const NativeVoicePort(),
  });

  @override
  State<ClientVoiceProfilePage> createState() => _ClientVoiceProfilePageState();
}

class _ClientVoiceProfilePageState extends State<ClientVoiceProfilePage> {
  Map<String, dynamic> profiles = const {};
  StreamSubscription<Map<String, dynamic>>? sub;
  String? voiceId;
  bool joinWeather = false, loaded = false, recording = false, busy = false;
  String? status;

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
      sub = widget.api.watch('care/${widget.hostId}/voiceProfiles').listen((v) {
        setState(() {
          profiles = v;
          if (!loaded) {
            final mine = asMap(v[me]);
            voiceId = mine['introVoiceId'] as String?;
            joinWeather = mine['joinWeather'] == true;
            loaded = true;
          }
        });
      }, onError: (Object e) => setState(() => status = errorMessage(e)));
    } catch (e) {
      status = errorMessage(e);
    }
  }

  @override
  void dispose() {
    sub?.cancel();
    if (recording) unawaited(widget.voice.cancel().catchError((_) {}));
    super.dispose();
  }

  Future<void> _start() async {
    if (recording || busy) return;
    if (!await widget.voice.ensurePermission()) {
      setState(() => status = '需要允許使用麥克風才能錄音');
      return;
    }
    try {
      await widget.voice.start();
      setState(() {
        recording = true;
        status = '錄音中…說「阿嬤，我是（你的名字）」這類自我介紹，說完放開';
      });
    } catch (e) {
      setState(() => status = '無法錄音：${errorMessage(e)}');
    }
  }

  Future<void> _stop() async {
    if (!recording) return;
    setState(() => recording = false);
    try {
      final note = await widget.voice.stop();
      final audio = note['audioBase64'], ms = note['durationMs'];
      if (audio is! String || ms is! num) {
        setState(() => status = '太短了，請按住久一點');
        return;
      }
      setState(() {
        busy = true;
        status = '正在上傳…';
      });
      final r = await widget.api.call('uploadReminderVoice', {
        'hostId': widget.hostId,
        'audioBase64': audio,
        'durationMs': ms.toInt(),
      });
      voiceId = r['voiceId'] as String?;
      await _save('錄好了，長輩手機下次連線會存下來');
    } catch (e) {
      setState(() => status = '沒有上傳：${errorMessage(e)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _save(String ok) async {
    setState(() => busy = true);
    try {
      await widget.api.call('setVoiceProfile', {
        'hostId': widget.hostId,
        'introVoiceId': voiceId,
        'joinWeather': joinWeather && voiceId != null,
      });
      if (mounted) setState(() => status = ok);
    } catch (e) {
      if (mounted) setState(() => status = '沒有儲存：${errorMessage(e)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// Stop using my voice anywhere: messages, reminders and the morning.
  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('不要用我的聲音？'),
        content: const Text('長輩手機在你的留言、提醒和早安前，都不會再播你的聲音，改用手機內建語音。之後想用可以再錄。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('不要用'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final previous = voiceId;
    setState(() {
      voiceId = null;
      joinWeather = false;
    });
    await _save('已停用，長輩手機下次連線後就不會播你的聲音');
    if (mounted && status?.startsWith('沒有儲存') == true) {
      setState(() => voiceId = previous);
    }
  }

  Future<void> _listen() async {
    final id = voiceId;
    if (id == null) return;
    try {
      final r = await widget.api.call('getReminderVoice', {
        'hostId': widget.hostId,
        'voiceId': id,
      });
      await widget.voice.play(r['audioBase64'] as String);
    } catch (e) {
      setState(() => status = '無法播放：${errorMessage(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final rotation = [
      for (final e in profiles.entries)
        if (asMap(e.value)['joinWeather'] == true)
          e.key == me ? '我' : (asMap(e.value)['name'] as String? ?? '家人'),
    ];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          '錄一句「阿嬤，我是小明」這樣的自我介紹（稱呼換成你家長輩）。長輩手機會在你設的提醒、你傳的文字留言前先播這段，讓長輩聽到你的聲音。不想用時，按下面「不要用我的聲音」。',
          style: TextStyle(fontSize: 16),
        ),
        const SizedBox(height: 16),
        GestureDetector(
          key: const Key('intro-record'),
          onLongPressStart: (_) => _start(),
          onLongPressEnd: (_) => _stop(),
          onLongPressCancel: () {
            if (recording) {
              setState(() => recording = false);
              unawaited(widget.voice.cancel().catchError((_) {}));
            }
          },
          child: Container(
            height: 72,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: recording ? FhColors.dangerSoft : FhColors.brand,
              borderRadius: BorderRadius.circular(36),
            ),
            child: Text(
              recording
                  ? '錄音中…放開完成'
                  : voiceId == null
                  ? '按住錄自我介紹'
                  : '按住重錄',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: recording ? FhColors.danger : Colors.white,
              ),
            ),
          ),
        ),
        if (voiceId != null)
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: _listen,
                icon: const Icon(Icons.play_arrow),
                label: const Text('試聽我的自我介紹'),
              ),
              TextButton.icon(
                key: const Key('intro-remove'),
                onPressed: busy ? null : _remove,
                icon: const Icon(Icons.voice_over_off),
                label: const Text('不要用我的聲音'),
              ),
            ],
          ),
        const Divider(height: 32),
        SwitchListTile(
          key: const Key('join-weather'),
          value: joinWeather && voiceId != null,
          onChanged: voiceId == null || busy
              ? null
              : (v) {
                  setState(() => joinWeather = v);
                  _save(v ? '已加入早安天氣輪流' : '已退出早安天氣輪流');
                },
          title: const Text('加入早安天氣輪流', style: TextStyle(fontSize: 18)),
          subtitle: Text(
            voiceId == null
                ? '先錄好自我介紹才能加入'
                : '只影響早安：有加入的家人每天輪一位，用他的聲音說早安。留言和提醒前仍會播你的聲音。',
          ),
        ),
        Text(
          rotation.isEmpty
              ? '目前沒有人加入，早安用手機內建語音。'
              : '目前輪流：${rotation.join('、')}（一人一天）',
          style: const TextStyle(fontSize: 16),
        ),
        if (status != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(status!, style: const TextStyle(fontSize: 16)),
          ),
      ],
    );
  }
}
