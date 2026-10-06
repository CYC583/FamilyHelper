// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../common/control_protocol.dart';
import '../common/firebase_service.dart';
import '../common/rtc_session.dart';
import '../common/ui/fh_tokens.dart';

class NoTurnNotice extends StatelessWidget {
  final bool hasTurn;
  const NoTurnNotice({super.key, required this.hasTurn});

  @override
  Widget build(BuildContext context) {
    if (hasTurn) return const SizedBox.shrink();
    return Semantics(
      liveRegion: true,
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          '這次未取得跨網路轉接，遠端協助可能無法連線；請改用電話聯絡。',
          style: TextStyle(
            fontSize: 16,
            color: FhColors.warning,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class RemoteViewPage extends StatefulWidget {
  final FirebaseService api;
  final String id;

  /// False for grandma's SOS: a video call only, no phone screen.
  final bool shareScreen;
  const RemoteViewPage({
    super.key,
    required this.api,
    required this.id,
    this.shareScreen = true,
  });
  @override
  State<RemoteViewPage> createState() => _RemoteViewPageState();
}

class _RemoteViewPageState extends State<RemoteViewPage> {
  late final rtc = RtcSession(api: widget.api, id: widget.id, isHost: false);
  final message = TextEditingController();
  bool leaving = false;
  @override
  void initState() {
    super.initState();
    rtc.addListener(update);
    unawaited(
      rtc.initialize().catchError((Object e) {
        rtc.error = errorMessage(e);
        rtc.close();
      }),
    );
  }

  void update() {
    if (mounted) setState(() {});
  }

  Future<void> endAndBack() async {
    if (leaving) return;
    leaving = true;
    await rtc.close();
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    rtc.removeListener(update);
    rtc.releaseRenderers();
    message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: rtc.closed,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) endAndBack();
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(widget.shareScreen ? '遠端協助' : '和長輩視訊'),
        actions: [
          IconButton(
            tooltip: '結束連線',
            onPressed: endAndBack,
            icon: const Icon(Icons.call_end, color: FhColors.danger),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(rtc.status, style: const TextStyle(fontSize: 18)),
            ),
            NoTurnNotice(hasTurn: rtc.hasTurn),
            Expanded(
              child: !rtc.renderersReady
                  ? const Center(child: CircularProgressIndicator())
                  : widget.shareScreen
                  ? RemoteScreen(session: rtc)
                  : ColoredBox(
                      key: const Key('sos-video'),
                      color: Colors.black,
                      child: RTCVideoView(
                        rtc.remoteCamera,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                      ),
                    ),
            ),
            if (!rtc.closed) CallControls(session: rtc),
            if (rtc.renderersReady && !rtc.closed && widget.shareScreen)
              SizedBox(
                height: 96,
                child: Row(
                  children: [
                    Expanded(
                      child: RTCVideoView(
                        rtc.remoteCamera,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                      ),
                    ),
                    Expanded(
                      child: RTCVideoView(
                        rtc.local,
                        mirror: true,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: message,
                      maxLength: 140,
                      decoration: const InputDecoration(
                        labelText: '給長輩的大字訊息',
                        counterText: '',
                      ),
                      onSubmitted: (_) => sendText(),
                    ),
                  ),
                  IconButton(
                    tooltip: '傳送大字訊息',
                    onPressed: rtc.controlReady ? sendText : null,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
            if (rtc.closed)
              Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton(
                  onPressed: endAndBack,
                  child: const Text('返回'),
                ),
              ),
          ],
        ),
      ),
    ),
  );
  void sendText() {
    final text = message.text.trim();
    if (text.isEmpty || !rtc.controlReady) return;
    rtc.send({'type': 'text', 'text': text});
    message.clear();
  }
}

/// 擴音 and microphone switches, used by both phones during a call.
class CallControls extends StatelessWidget {
  final RtcSession session;
  final bool large;
  const CallControls({super.key, required this.session, this.large = false});

  @override
  Widget build(BuildContext context) {
    final size = large ? 22.0 : 16.0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              key: const Key('call-speaker'),
              style: OutlinedButton.styleFrom(
                minimumSize: Size(48, large ? 72 : 52),
              ),
              onPressed: () => session.setSpeaker(!session.speakerOn),
              icon: Icon(
                session.speakerOn ? Icons.volume_up : Icons.hearing,
                size: large ? 32 : 24,
              ),
              label: Text(
                session.speakerOn ? '擴音：開' : '擴音：關',
                style: TextStyle(fontSize: size),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              key: const Key('call-mic'),
              style: OutlinedButton.styleFrom(
                minimumSize: Size(48, large ? 72 : 52),
              ),
              onPressed: () => session.setMicMuted(!session.micMuted),
              icon: Icon(
                session.micMuted ? Icons.mic_off : Icons.mic,
                size: large ? 32 : 24,
              ),
              label: Text(
                session.micMuted ? '麥克風：關' : '麥克風：開',
                style: TextStyle(fontSize: size),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class RemoteScreen extends StatefulWidget {
  final RtcSession session;
  const RemoteScreen({super.key, required this.session});
  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen> {
  Offset? start;
  DateTime? downAt;
  int? pointer;
  String? startShape;
  RtcSession get rtc => widget.session;
  String get shape =>
      '${rtc.geometry?['width']}:${rtc.geometry?['height']}:${rtc.geometry?['rotation']}';
  @override
  Widget build(BuildContext context) => rtc.closed
      ? const ColoredBox(
          color: Colors.black,
          child: Center(
            child: Text(
              '畫面分享已結束',
              style: TextStyle(color: Colors.white, fontSize: 24),
            ),
          ),
        )
      : LayoutBuilder(
          builder: (context, constraints) {
            final view = Size(constraints.maxWidth, constraints.maxHeight);
            final frame = Size(
              rtc.remoteScreen.videoWidth.toDouble(),
              rtc.remoteScreen.videoHeight.toDouble(),
            );
            final g = rtc.geometry;
            final w = (g?['width'] as num?)?.toDouble() ?? 0,
                h = (g?['height'] as num?)?.toDouble() ?? 0;
            // A rotation or stale frame invalidates input until matching frames arrive.
            final canControl =
                rtc.controlReady &&
                g?['accessibility'] == true &&
                !frame.isEmpty &&
                w > 0 &&
                h > 0 &&
                (frame.aspectRatio - w / h).abs() < 0.03;
            return ColoredBox(
              color: Colors.black,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (event) {
                  if (pointer != null) {
                    pointer = -1;
                    start = null;
                    return;
                  }
                  if (!canControl) return;
                  pointer = event.pointer;
                  start = normalizedPoint(event.localPosition, view, frame);
                  downAt = DateTime.now();
                  startShape = shape;
                },
                onPointerCancel: (_) {
                  pointer = null;
                  start = null;
                },
                onPointerUp: (event) {
                  final a = start, time = downAt;
                  final matches = pointer == event.pointer;
                  pointer = null;
                  start = null;
                  downAt = null;
                  if (!matches ||
                      !canControl ||
                      a == null ||
                      time == null ||
                      startShape != shape) {
                    return;
                  }
                  final b = normalizedPoint(event.localPosition, view, frame);
                  if (b == null) return;
                  final distance = (b - a).distance;
                  if (distance > 0.025) {
                    rtc.sendGesture('swipe', a.dx, a.dy, x2: b.dx, y2: b.dy);
                  } else {
                    rtc.sendGesture(
                      DateTime.now().difference(time).inMilliseconds >= 500
                          ? 'longPress'
                          : 'tap',
                      a.dx,
                      a.dy,
                    );
                  }
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    RTCVideoView(
                      rtc.remoteScreen,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                      mirror: false,
                    ),
                    if (frame.isEmpty)
                      const Center(
                        child: Text(
                          '等待長輩分享畫面',
                          style: TextStyle(color: Colors.white, fontSize: 24),
                        ),
                      ),
                    if (!canControl && !frame.isEmpty)
                      Align(
                        alignment: Alignment.topCenter,
                        child: ColoredBox(
                          color: const Color(0xcca61f2a),
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: Text(
                              g != null && g['accessibility'] != true
                                  ? '目前只能看、不能操作：長輩手機還沒開「允許遠端點擊」。請長輩到「家人設定 → 允許遠端點擊」打開一次（只要開一次）。'
                                  : '畫面正在對準中，請稍等幾秒再點；如果長輩轉了手機方向，請轉回直的。',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
}
