// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_service.dart';
import 'native_bridge.dart';
import 'ui/fh_tokens.dart';
import 'ui/fh_format.dart';
import 'ui/fh_widgets.dart';

/// Microphone and playback, injectable for tests.
abstract class VoicePort {
  Future<bool> ensurePermission();
  Future<void> start();
  Future<Map<String, dynamic>> stop();
  Future<void> cancel();
  Future<void> play(String audioBase64);
  Future<void> stopPlay();

  /// 0..1 loudness for the live waveform.
  Future<double> level();
}

class NativeVoicePort implements VoicePort {
  const NativeVoicePort();
  @override
  Future<bool> ensurePermission() async {
    if (await Permission.microphone.isGranted) return true;
    return (await Permission.microphone.request()).isGranted;
  }

  @override
  Future<void> start() => NativeBridge.voiceStart();
  @override
  Future<Map<String, dynamic>> stop() => NativeBridge.voiceStop();
  @override
  Future<void> cancel() => NativeBridge.voiceCancel();
  @override
  Future<void> play(String audioBase64) => NativeBridge.voicePlay(audioBase64);
  @override
  Future<void> stopPlay() => NativeBridge.voiceStopPlay();
  @override
  Future<double> level() async =>
      ((await NativeBridge.voiceLevel())['level'] as num?)?.toDouble() ?? 0;
}

/// Family conversation as chat bubbles. Grandma's side has no text box: she
/// holds one big button to talk. Nothing is shown as sent until the server
/// accepts it; voice notes are at most 30 seconds, two per person per day.
class FamilyMessagesPanel extends StatefulWidget {
  final FirebaseService api;
  final String hostId;
  final String selfUid;
  final bool isHost;
  final Map<String, String> names;

  /// What the family calls grandma (her own display name).
  final String hostName;
  final Stream<Map<String, dynamic>>? messages;
  final VoicePort voice;
  final DateTime Function() clock;

  /// Called for a newly arrived message from someone else (host reads aloud).
  final void Function(String who, Map<String, dynamic> message)? onIncoming;

  /// Chat-app layout: newest messages just above a talk button pinned at the
  /// bottom. Needs a bounded height (a whole tab); off inside scroll views.
  final bool fillHeight;

  /// Start in "tap to start, tap to stop" mode instead of hold-to-talk;
  /// null means use this phone's saved choice.
  final bool? tapMode;

  const FamilyMessagesPanel({
    super.key,
    required this.api,
    required this.hostId,
    required this.selfUid,
    required this.isHost,
    this.names = const {},
    this.hostName = '長輩',
    this.messages,
    this.voice = const NativeVoicePort(),
    this.clock = DateTime.now,
    this.onIncoming,
    this.fillHeight = false,
    this.tapMode,
  });

  @override
  State<FamilyMessagesPanel> createState() => _FamilyMessagesPanelState();
}

class _FamilyMessagesPanelState extends State<FamilyMessagesPanel> {
  final _text = TextEditingController();
  Stream<Map<String, dynamic>>? _stream;
  StreamSubscription<Map<String, dynamic>>? _incomingSub;
  String? _streamError;
  bool _sending = false, _recording = false;
  String? _status, _playing;
  Timer? _limit, _meter;
  final _levels = List<double>.filled(24, 0, growable: true);
  int _seconds = 0;
  DateTime? _recordStarted;
  StreamSubscription<String>? _native;
  late final int _openedAt = widget.clock().millisecondsSinceEpoch;
  final _announced = <String>{};
  late bool _tapMode = widget.tapMode ?? false;

  /// A recording waiting to be sent (tap mode preview, or a failed send).
  Map<String, dynamic>? _pendingVoice;
  bool _pendingFailed = false;
  static const _modeKey = 'voice_tap_mode';

  @override
  void initState() {
    super.initState();
    try {
      _stream =
          (widget.messages ??
                  widget.api.watch('care/${widget.hostId}/messages/items'))
              .asBroadcastStream();
      _incomingSub = _stream!.listen(_detectIncoming, onError: (_) {});
    } catch (e) {
      _streamError = errorMessage(e);
    }
    if (widget.tapMode == null) {
      SharedPreferences.getInstance()
          .then((p) {
            if (mounted) {
              setState(() => _tapMode = p.getBool(_modeKey) ?? false);
            }
          })
          .catchError((_) {});
    }
    _native = NativeBridge.events.stream.listen((event) {
      if (event == 'voiceDone' && mounted) setState(() => _playing = null);
    });
  }

  void _detectIncoming(Map<String, dynamic> raw) {
    final handler = widget.onIncoming;
    if (handler == null) return;
    raw.forEach((id, value) {
      final m = asMap(value);
      final author = m['authorId'];
      final created = (m['createdAt'] as num?)?.toInt() ?? 0;
      if (author is! String ||
          author == widget.selfUid ||
          created <= _openedAt ||
          !_announced.add(id)) {
        return;
      }
      if (m['kind'] == 'voice' && m['status'] != 'ready') {
        _announced.remove(id);
        return;
      }
      handler(_name(author), m);
    });
  }

  @override
  void dispose() {
    _limit?.cancel();
    _meter?.cancel();
    _native?.cancel();
    _incomingSub?.cancel();
    if (_recording) unawaited(widget.voice.cancel().catchError((_) {}));
    _text.dispose();
    super.dispose();
  }

  String _name(String uid) => uid == widget.hostId
      ? widget.hostName
      : uid == widget.selfUid
      ? '我'
      : widget.names[uid] ?? '家人';

  Future<bool> _send(Map<String, dynamic> payload, String okText) async {
    setState(() {
      _sending = true;
      _status = '正在傳送…';
    });
    try {
      await widget.api.call('sendCareMessage', {
        'hostId': widget.hostId,
        ...payload,
      });
      if (!mounted) return true;
      setState(() => _status = okText);
      _text.clear();
      if (widget.isHost) {
        unawaited(NativeBridge.speakText(okText).catchError((_) {}));
      }
      return true;
    } catch (e) {
      if (mounted) {
        setState(
          () => _status = widget.isHost
              ? '沒有送出，按「再傳一次」'
              : '沒有送出：${errorMessage(e)}',
        );
      }
      if (widget.isHost) {
        unawaited(NativeBridge.speakText('沒有送出，請再試一次').catchError((_) {}));
      }
      return false;
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendText(String value) async {
    final text = value.trim();
    if (text.isEmpty || text.length > 80) {
      setState(() => _status = '文字需為 1 到 80 字');
      return;
    }
    await _send({'kind': 'text', 'text': text}, '已送出');
  }

  Future<void> _startRecord() async {
    if (_recording || _sending) return;
    setState(() => _status = null);
    try {
      if (!await widget.voice.ensurePermission()) {
        setState(() => _status = '需要允許使用麥克風，才能錄音');
        return;
      }
      await widget.voice.start();
      unawaited(HapticFeedback.mediumImpact().catchError((_) {}));
      if (!mounted) return;
      _recordStarted = widget.clock();
      setState(() {
        _recording = true;
        _seconds = 0;
        _levels.fillRange(0, _levels.length, 0);
      });
      _meter = Timer.periodic(const Duration(milliseconds: 120), (_) async {
        double level = 0;
        try {
          level = await widget.voice.level();
        } catch (_) {}
        if (!mounted || !_recording) return;
        setState(() {
          _levels
            ..removeAt(0)
            ..add(level);
          _seconds = widget.clock().difference(_recordStarted!).inSeconds;
        });
      });
      _limit = Timer(const Duration(seconds: 30), _finishRecord);
    } catch (e) {
      if (mounted) setState(() => _status = '無法錄音：${errorMessage(e)}');
    }
  }

  Future<void> _finishRecord() async {
    _limit?.cancel();
    _meter?.cancel();
    if (!_recording) return;
    setState(() => _recording = false);
    unawaited(HapticFeedback.lightImpact().catchError((_) {}));
    try {
      final note = await widget.voice.stop();
      final audio = note['audioBase64'];
      final duration = note['durationMs'];
      if (audio is! String || duration is! num) {
        setState(() => _status = _tapMode ? '太短了，請再錄一次' : '太短了，請按住久一點再說');
        return;
      }
      final voice = {
        'kind': 'voice',
        'audioBase64': audio,
        'durationMs': duration.toInt(),
      };
      if (_tapMode) {
        // Tap mode: listen first, then choose 傳送 or 重錄.
        setState(() {
          _pendingVoice = voice;
          _pendingFailed = false;
          _status = '錄好了，可以先聽聽看，再按傳送';
        });
        return;
      }
      await _sendPending(voice);
    } catch (e) {
      if (mounted) setState(() => _status = '錄音失敗：${errorMessage(e)}');
    }
  }

  /// Keeps the recording when sending fails so nothing has to be re-recorded.
  Future<void> _sendPending(Map<String, dynamic> voice) async {
    final ok = await _send(voice, '語音已送出');
    if (!mounted) return;
    setState(() {
      _pendingVoice = ok ? null : voice;
      _pendingFailed = !ok;
    });
  }

  Future<void> _setMode(bool tap) async {
    setState(() => _tapMode = tap);
    try {
      (await SharedPreferences.getInstance()).setBool(_modeKey, tap);
    } catch (_) {}
  }

  Future<void> _cancelRecord() async {
    _limit?.cancel();
    _meter?.cancel();
    if (!_recording) return;
    setState(() {
      _recording = false;
      _status = '已取消，沒有送出';
    });
    await widget.voice.cancel().catchError((_) {});
  }

  Future<void> _play(String id) async {
    if (_playing == id) {
      await widget.voice.stopPlay().catchError((_) {});
      setState(() => _playing = null);
      return;
    }
    setState(() {
      _playing = id;
      _status = '正在下載語音…';
    });
    try {
      final result = await widget.api.call('getVoiceMessage', {
        'hostId': widget.hostId,
        'id': id,
      });
      final audio = result['audioBase64'];
      if (audio is! String) throw StateError('語音資料不完整');
      await widget.voice.play(audio);
      if (mounted) setState(() => _status = null);
    } catch (e) {
      if (mounted) {
        setState(() {
          _playing = null;
          _status = '語音無法播放：${errorMessage(e)}';
        });
      }
    }
  }

  List<MapEntry<String, Map<String, dynamic>>> _visible(
    Map<String, dynamic> raw,
  ) {
    final now = widget.clock().millisecondsSinceEpoch;
    final rows = <MapEntry<String, Map<String, dynamic>>>[];
    raw.forEach((id, value) {
      final item = asMap(value);
      final author = item['authorId'];
      final expires = item['expiresAt'];
      if (author is! String || (expires is num && expires <= now)) return;
      if (author != widget.hostId &&
          author != widget.selfUid &&
          widget.names.isNotEmpty &&
          !widget.names.containsKey(author)) {
        return; // removed family member
      }
      if (item['kind'] == 'voice' &&
          item['status'] != 'ready' &&
          author != widget.selfUid) {
        return;
      }
      rows.add(MapEntry(id, item));
    });
    rows.sort(
      (a, b) => ((a.value['createdAt'] as num?) ?? 0).compareTo(
        (b.value['createdAt'] as num?) ?? 0,
      ),
    );
    return rows.length > 30 ? rows.sublist(rows.length - 30) : rows;
  }

  String _clock(Object? millis) {
    if (millis is! num) return '';
    return friendlyTime(millis, taipei: true);
  }

  Widget _bubble(String id, Map<String, dynamic> m, double size) {
    final mine = m['authorId'] == widget.selfUid;
    final color = mine ? FhColors.brandSoft : Colors.white;
    final voice = m['kind'] == 'voice';
    final seconds = (((m['durationMs'] as num?) ?? 0) / 1000).round();
    return Align(
      key: Key('message-$id'),
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(mine ? 18 : 4),
              bottomRight: Radius.circular(mine ? 4 : 18),
            ),
            border: Border.all(color: FhColors.outline),
          ),
          child: Column(
            crossAxisAlignment: mine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              Text(
                '${_name(m['authorId'] as String)}・${_clock(m['createdAt'])}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              if (!voice)
                Text(
                  '${m['text'] ?? ''}',
                  style: Theme.of(context).textTheme.bodyLarge,
                )
              else if (m['status'] != 'ready')
                Text('語音傳送中…', style: Theme.of(context).textTheme.bodyLarge)
              else
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: Size(48, widget.isHost ? 64 : 48),
                  ),
                  onPressed: () => _play(id),
                  icon: Icon(
                    _playing == id ? Icons.stop_circle : Icons.play_circle,
                    size: widget.isHost ? 36 : 26,
                  ),
                  label: Text(
                    _playing == id ? '停止' : '聽語音 $seconds 秒',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _waveform() => Row(
    key: const Key('voice-waveform'),
    mainAxisAlignment: MainAxisAlignment.center,
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      for (final v in _levels)
        AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          width: 6,
          height: 8 + 56 * v.clamp(0.0, 1.0),
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: FhColors.danger,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
    ],
  );

  Widget _bigButton(
    String label,
    IconData icon,
    Color color,
    VoidCallback? onTap, {
    Key? key,
  }) {
    final height = widget.isHost ? 96.0 : 60.0;
    return SizedBox(
      height: height,
      child: FilledButton.icon(
        key: key,
        style: FilledButton.styleFrom(
          backgroundColor: color,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(height / 2),
          ),
        ),
        onPressed: onTap,
        icon: Icon(icon, size: widget.isHost ? 36 : 24),
        label: Text(label, style: Theme.of(context).textTheme.labelLarge),
      ),
    );
  }

  /// Pending recording → listen / send / re-record; otherwise the chosen mode.
  Widget _voiceArea() {
    const green = FhColors.brand, red = FhColors.danger;
    final pending = _pendingVoice;
    final Widget main;
    if (pending != null && !_recording) {
      main = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: _bigButton(
                  '試聽',
                  Icons.play_arrow,
                  FhColors.inkMuted,
                  () => widget.voice
                      .play(pending['audioBase64'] as String)
                      .catchError((_) {}),
                  key: const Key('voice-preview'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _bigButton(
                  '重錄',
                  Icons.refresh,
                  FhColors.inkMuted,
                  _sending
                      ? null
                      : () => setState(() {
                          _pendingVoice = null;
                          _pendingFailed = false;
                          _status = null;
                        }),
                  key: const Key('voice-rerecord'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _bigButton(
            _sending ? '傳送中…' : (_pendingFailed ? '再傳一次' : '傳送'),
            Icons.send,
            green,
            _sending ? null : () => _sendPending(pending),
            key: const Key('voice-send'),
          ),
        ],
      );
    } else if (_tapMode) {
      main = _recording
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _waveform(),
                Text(
                  '錄音中 $_seconds 秒',
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(color: red),
                ),
                const SizedBox(height: 6),
                _bigButton(
                  '停止錄音',
                  Icons.stop,
                  red,
                  _finishRecord,
                  key: const Key('voice-tap-stop'),
                ),
                TextButton(
                  onPressed: _cancelRecord,
                  child: Text(
                    '取消',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
              ],
            )
          : _bigButton(
              '點一下開始錄音',
              Icons.mic,
              green,
              _sending ? null : _startRecord,
              key: const Key('voice-tap-start'),
            );
    } else {
      main = _talkButton();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        main,
        if (!_recording && pending == null)
          TextButton(
            key: const Key('voice-mode'),
            onPressed: () => _setMode(!_tapMode),
            child: Text(
              _tapMode ? '改成「按住說話」' : '改成「點一下錄音」',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  Widget _talkButton() {
    final height = widget.isHost ? 120.0 : 72.0;
    return Semantics(
      button: true,
      label: _recording ? '錄音中，放開送出' : '按住說話',
      child: GestureDetector(
        key: const Key('voice-record'),
        onLongPressStart: (_) => _startRecord(),
        onLongPressEnd: (_) => _finishRecord(),
        onLongPressCancel: _cancelRecord,
        onTap: () {
          if (_recording) {
            _finishRecord();
          } else {
            setState(() => _status = '請「按住」按鈕說話，說完放開就送出');
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: height,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _recording ? FhColors.dangerSoft : FhColors.brand,
            borderRadius: BorderRadius.circular(height / 2),
            border: Border.all(
              color: _recording ? FhColors.danger : Colors.transparent,
              width: 3,
            ),
          ),
          child: _recording
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _waveform(),
                    Text(
                      '錄音中 $_seconds 秒，放開就送出',
                      style: Theme.of(
                        context,
                      ).textTheme.titleMedium?.copyWith(color: FhColors.danger),
                    ),
                  ],
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.mic,
                      color: Colors.white,
                      size: widget.isHost ? 44 : 28,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _sending ? '傳送中…' : '按住說話',
                      style: Theme.of(
                        context,
                      ).textTheme.headlineMedium?.copyWith(color: Colors.white),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _messageList(double size) {
    if (_streamError != null) {
      return FhStatusBanner(
        tone: FhTone.danger,
        message: '留言暫時無法讀取：$_streamError',
      );
    }
    return StreamBuilder<Map<String, dynamic>>(
      stream: _stream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return FhStatusBanner(
            tone: FhTone.danger,
            message: '留言暫時無法讀取：${errorMessage(snapshot.error!)}',
          );
        }
        if (!snapshot.hasData) return const FhStatusBanner(message: '正在讀取留言…');
        final rows = _visible(snapshot.data!);
        if (rows.isEmpty) {
          final empty = FhEmptyState(
            icon: Icons.chat_bubble_outline,
            title: widget.isHost ? '還沒有留言。按住下面的按鈕跟家人說話吧！' : '還沒有留言',
          );
          return widget.fillHeight ? Center(child: empty) : empty;
        }
        if (!widget.fillHeight) {
          return Column(
            children: [for (final r in rows) _bubble(r.key, r.value, size)],
          );
        }
        // reverse: index 0 is the newest message, drawn at the bottom.
        return ListView.builder(
          key: const Key('message-list'),
          reverse: true,
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: rows.length,
          itemBuilder: (_, index) {
            final r = rows[rows.length - 1 - index];
            return _bubble(r.key, r.value, size);
          },
        );
      },
    );
  }

  List<Widget> _composer(double size) => [
    if (!widget.isHost)
      Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('message-input'),
              controller: _text,
              maxLength: 80,
              decoration: const InputDecoration(
                labelText: '寫一句話給長輩',
                counterText: '',
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            key: const Key('message-send'),
            onPressed: _sending || _recording
                ? null
                : () => _sendText(_text.text),
            child: const Text('傳送'),
          ),
        ],
      ),
    const SizedBox(height: 8),
    _voiceArea(),
    if (_status != null)
      Semantics(
        liveRegion: true,
        child: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: FhStatusBanner(message: _status!),
        ),
      ),
    if (!widget.fillHeight)
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          '每則語音最多 30 秒；留言保留 30 天。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final size = widget.isHost ? 24.0 : 17.0;
    if (widget.fillHeight) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _messageList(size)),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _composer(size),
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _messageList(size),
        const SizedBox(height: 12),
        ..._composer(size),
      ],
    );
  }
}
