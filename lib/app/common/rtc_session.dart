// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:permission_handler/permission_handler.dart';
import 'control_protocol.dart';
import 'firebase_service.dart';
import 'native_bridge.dart';

/// One instance owns all resources for one consented session. No renegotiation
/// or automatic reconnect: a failed connection requires fresh local consent.
class RtcSession extends ChangeNotifier {
  final FirebaseService api;
  final String id;
  final bool isHost;

  /// Host only: false for an SOS call (camera and microphone, no screen).
  final bool shareScreen;
  final local = RTCVideoRenderer();
  final remoteScreen = RTCVideoRenderer();
  final remoteCamera = RTCVideoRenderer();
  RTCPeerConnection? _pc;
  RTCDataChannel? _channel;
  MediaStream? _camera, _screen;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final List<RTCIceCandidate> _waitingIce = [];
  final Set<String> _seenIce = {};
  Timer? _heartbeat, _controlHeartbeat, _deadline, _connectionDeadline;
  bool _remoteDescriptionSet = false, _closed = false, _started = false;
  bool _handlingDescription = false, _serverHeartbeatBusy = false;
  bool _renderersReady = false;
  Future<void>? _closeFuture;
  String status = '等待長輩同意';
  String? error;
  bool connected = false, hasTurn = true;
  bool speakerOn = true, micMuted = false;

  /// Loudspeaker (擴音) on/off; both sides start with it on.
  Future<void> setSpeaker(bool on) async {
    speakerOn = on;
    await Helper.setSpeakerphoneOn(on);
    _changed();
  }

  /// Mute or unmute this phone's microphone without ending the call.
  void setMicMuted(bool muted) {
    micMuted = muted;
    for (final track
        in _camera?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
    _changed();
  }

  Map<String, dynamic>? geometry;
  String? _screenStreamId;
  int _sequence = 0, _localIceCount = 0;
  DateTime _lastPeerMessage = DateTime.now();
  bool get closed => _closed;
  bool get renderersReady => _renderersReady;
  bool get controlReady =>
      connected &&
      geometry != null &&
      _channel?.state == RTCDataChannelState.RTCDataChannelOpen;
  DatabaseReference get signal => api.database.ref('signals/$id');
  String get side => isHost ? 'host' : 'client';
  String get other => isHost ? 'client' : 'host';
  RtcSession({
    required this.api,
    required this.id,
    required this.isHost,
    this.shareScreen = true,
  });

  void _changed() {
    notifyListeners();
  }

  void _checkOpen() {
    if (_closed) throw StateError('連線已結束');
  }

  Future<void> initialize() async {
    await Future.wait([
      local.initialize(),
      remoteScreen.initialize(),
      remoteCamera.initialize(),
    ]);
    _renderersReady = true;
    if (_closed) {
      _renderersReady = false;
      await local.dispose();
      await remoteScreen.dispose();
      await remoteCamera.dispose();
      return;
    }
    remoteScreen.onResize = _changed;
    _subscriptions.add(
      NativeBridge.events.stream.listen((event) {
        if (event == 'stop') unawaited(close());
      }),
    );
    _subscriptions.add(
      api
          .session(id)
          .listen(
            (value) async {
              if (_closed) return;
              final state = value['status'];
              if (value.isEmpty ||
                  ['ended', 'rejected', 'expired'].contains(state)) {
                error = state == 'rejected' ? '長輩已拒絕這次連線' : '連線已結束';
                await close(notifyServer: false);
                return;
              }
              if (state == 'accepted' && !_started) {
                _started = true;
                _deadline?.cancel();
                final expires = value['expiresAt'] as int;
                _deadline = Timer(
                  Duration(
                    milliseconds:
                        (expires - DateTime.now().millisecondsSinceEpoch)
                            .clamp(0, 1800000)
                            .toInt(),
                  ),
                  () => close(),
                );
                _startHeartbeat();
                try {
                  await _start();
                } catch (e) {
                  error = errorMessage(e);
                  await close();
                }
              }
            },
            onError: (Object e) {
              error = errorMessage(e);
              unawaited(close(notifyServer: false));
            },
          ),
    );
    _deadline = Timer(const Duration(seconds: 90), () {
      error = '等待同意逾時';
      close();
    });
    _changed();
  }

  void _startHeartbeat() {
    _heartbeat = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (_closed || _serverHeartbeatBusy) return;
      _serverHeartbeatBusy = true;
      try {
        await api
            .call('heartbeat', {'sessionId': id})
            .timeout(const Duration(seconds: 8));
      } catch (_) {
        error = '網路中斷，已停止協助';
        await close();
      } finally {
        _serverHeartbeatBusy = false;
      }
    });
  }

  Future<MediaStream> _acquire(Future<MediaStream> future) async {
    final stream = await future;
    if (_closed) {
      await _release(stream);
      throw StateError('連線已結束');
    }
    return stream;
  }

  Future<void> _start() async {
    status = '準備通話';
    _changed();
    final permissions = await [
      Permission.camera,
      Permission.microphone,
    ].request();
    _checkOpen();
    if (permissions.values.any((v) => !v.isGranted)) {
      throw Exception('請允許相機及麥克風，再重新連線');
    }
    if (isHost && !shareScreen) {
      if (!await NativeBridge.activateCall(id)) {
        throw Exception('請在長輩手機上重新按一次');
      }
    }
    if (isHost && shareScreen) {
      // Explicitly request NEW full-screen consent each session. Never reuse a token.
      if (!await Helper.requestCapturePermission(fullScreenOnly: true)) {
        throw Exception('螢幕分享已取消');
      }
      _checkOpen();
      // The native method completes only after startForeground succeeds.
      await NativeBridge.startCapture(id);
      if (_closed) {
        await NativeBridge.stop();
        _checkOpen();
      }
      _screen = await _acquire(
        navigator.mediaDevices.getDisplayMedia({'video': true, 'audio': false}),
      );
      for (final track in _screen!.getVideoTracks()) {
        track.onEnded = () => close();
      }
    }
    await NativeBridge.startCall();
    if (_closed) {
      await NativeBridge.stop();
      _checkOpen();
    }
    _camera = await _acquire(
      navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': {
          'facingMode': 'user',
          'width': 640,
          'height': 480,
          'frameRate': 20,
        },
      }),
    );
    local.srcObject = _camera;
    local.muted = true;
    await Helper.setSpeakerphoneOn(true);
    final config = await api.call('getIceServers', {'sessionId': id});
    _checkOpen();
    hasTurn = config['hasTurn'] == true;
    final pc = await createPeerConnection({
      'iceServers': config['iceServers'],
      'sdpSemantics': 'unified-plan',
    });
    if (_closed) {
      await pc.dispose();
      _checkOpen();
    }
    _pc = pc;
    pc.onIceCandidate = (candidate) async {
      if (_closed ||
          candidate.candidate == null ||
          candidate.candidate!.isEmpty) {
        return;
      }
      if (_localIceCount >= 128) return;
      final index = _localIceCount++;
      try {
        await signal.child('ice/$side/$index').set(candidate.toMap());
      } catch (_) {
        if (!_closed) {
          error = '信令傳送失敗';
          await close();
        }
      }
    };
    pc.onConnectionState = (state) {
      if (_closed) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _connectionDeadline?.cancel();
        connected = true;
        status = '協助中';
        _changed();
      } else if ([
        RTCPeerConnectionState.RTCPeerConnectionStateFailed,
        RTCPeerConnectionState.RTCPeerConnectionStateDisconnected,
        RTCPeerConnectionState.RTCPeerConnectionStateClosed,
      ].contains(state)) {
        error = '連線中斷，請重新取得長輩同意';
        unawaited(close());
      }
    };
    pc.onTrack = (event) {
      if (_closed || event.streams.isEmpty) return;
      final stream = event.streams.first;
      if (!isHost && stream.id == _screenStreamId) {
        remoteScreen.srcObject = stream;
      } else {
        remoteCamera.srcObject = stream;
      }
      _changed();
    };
    // Add camera/audio BEFORE the extra screen track, matching the answering
    // peer's m-line order. Screen gets its own stream ID and renderer.
    for (final track in _camera!.getTracks()) {
      await pc.addTrack(track, _camera!);
    }
    if (isHost) {
      for (final track in _screen?.getTracks() ?? const <MediaStreamTrack>[]) {
        await pc.addTransceiver(
          track: track,
          init: RTCRtpTransceiverInit(
            direction: TransceiverDirection.SendOnly,
            streams: [_screen!],
          ),
        );
      }
      _attachChannel(
        await pc.createDataChannel(
          'family-control-v1',
          RTCDataChannelInit()..ordered = true,
        ),
      );
    } else {
      pc.onDataChannel = _attachChannel;
    }
    _subscriptions.add(
      signal
          .child('ice/$other')
          .onChildAdded
          .listen(
            (event) async {
              if (_closed || !_seenIce.add(event.snapshot.key!)) return;
              final value = asMap(event.snapshot.value);
              final candidate = RTCIceCandidate(
                value['candidate'] as String?,
                value['sdpMid'] as String?,
                value['sdpMLineIndex'] as int?,
              );
              if (!_remoteDescriptionSet) {
                _waitingIce.add(candidate);
              } else {
                try {
                  await pc.addCandidate(candidate);
                } catch (_) {
                  error = 'ICE 信令無效';
                  await close();
                }
              }
            },
            onError: (Object _) {
              error = '信令讀取失敗';
              close();
            },
          ),
    );
    _subscriptions.add(
      signal
          .child(isHost ? 'answer' : 'offer')
          .onValue
          .listen(
            (event) async {
              if (_closed ||
                  _remoteDescriptionSet ||
                  _handlingDescription ||
                  !event.snapshot.exists) {
                return;
              }
              _handlingDescription = true;
              try {
                final data = asMap(event.snapshot.value);
                if (!isHost) {
                  _screenStreamId = data['screenStreamId'] as String?;
                }
                await pc.setRemoteDescription(
                  RTCSessionDescription(
                    data['sdp'] as String,
                    isHost ? 'answer' : 'offer',
                  ),
                );
                _remoteDescriptionSet = true;
                for (final candidate in _waitingIce) {
                  await pc.addCandidate(candidate);
                }
                _waitingIce.clear();
                if (!isHost) {
                  final answer = await pc.createAnswer();
                  await pc.setLocalDescription(answer);
                  _checkOpen();
                  await signal.child('answer').set({
                    'type': 'answer',
                    'sdp': answer.sdp,
                  });
                }
              } catch (e) {
                error = errorMessage(e);
                await close();
              } finally {
                _handlingDescription = false;
              }
            },
            onError: (Object _) {
              error = '信令讀取失敗';
              close();
            },
          ),
    );
    _checkOpen();
    if (isHost) {
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      _checkOpen();
      await signal.child('offer').set({
        'type': 'offer',
        'sdp': offer.sdp,
        'screenStreamId': _screen?.id ?? 'none',
      });
    }
    status = '正在建立連線';
    _changed();
    _connectionDeadline = Timer(const Duration(seconds: 45), () {
      error = '無法建立連線，請確認網路與 TURN 設定';
      close();
    });
  }

  void _attachChannel(RTCDataChannel channel) {
    if (_closed) {
      channel.close();
      return;
    }
    _channel = channel;
    channel.onMessage = (message) async {
      if (_closed || message.isBinary || message.text.length > 4096) return;
      try {
        final data = asMap(jsonDecode(message.text));
        if (data['sessionId'] != id) return;
        if (data['type'] == 'ping' && isHost) {
          _lastPeerMessage = DateTime.now();
          if (!await NativeBridge.keepAlive(id)) {
            error = '本機已停止遠端控制';
            await close();
            return;
          }
          final shape = await NativeBridge.geometry();
          send({'type': 'geometry', ...shape});
        } else if (data['type'] == 'geometry' && !isHost) {
          geometry = data;
          _lastPeerMessage = DateTime.now();
          _changed();
        } else if (data['type'] == 'text' && isHost && connected) {
          final value = data['text'];
          if (value is String && value.length <= 140) {
            await NativeBridge.showLargeMessage(value);
          }
        } else if (isHost && connected && validGesture(data, id)) {
          final ok = await NativeBridge.gesture(data);
          if (!ok) send({'type': 'controlBlocked'});
        } else if (!isHost && data['type'] == 'controlBlocked') {
          status = '此畫面暫停遠端操作，請長輩手動操作';
          _changed();
        }
      } catch (_) {
        /* Invalid/untrusted data cannot reach AccessibilityService. */
      }
    };
    void onState(RTCDataChannelState state) {
      if (_closed) return;
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _lastPeerMessage = DateTime.now();
        if (!isHost) send({'type': 'ping'});
        _controlHeartbeat?.cancel();
        _controlHeartbeat = Timer.periodic(const Duration(seconds: 2), (_) {
          if (DateTime.now().difference(_lastPeerMessage).inSeconds > 8) {
            error = '對方已失去連線';
            close();
            return;
          }
          if (!isHost) send({'type': 'ping'});
        });
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        close();
      }
      _changed();
    }

    channel.onDataChannelState = onState;
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      onState(channel.state!);
    }
  }

  void send(Map<String, dynamic> value) {
    if (_closed || _channel?.state != RTCDataChannelState.RTCDataChannelOpen) {
      return;
    }
    unawaited(
      _channel!
          .send(
            RTCDataChannelMessage(
              jsonEncode({...value, 'sessionId': id, 'seq': ++_sequence}),
            ),
          )
          .catchError((Object _) {}),
    );
  }

  void sendGesture(String type, double x, double y, {double? x2, double? y2}) {
    if (!controlReady) return;
    send({
      'type': type,
      'x': x,
      'y': y,
      if (x2 != null) 'x2': x2,
      if (y2 != null) 'y2': y2,
      'width': geometry!['width'],
      'height': geometry!['height'],
      'rotation': geometry!['rotation'],
    });
  }

  static Future<void> _release(MediaStream? stream) async {
    if (stream == null) return;
    for (final track in stream.getTracks()) {
      try {
        await track.stop();
      } catch (_) {}
    }
    try {
      await stream.dispose();
    } catch (_) {}
  }

  Future<void> close({bool notifyServer = true}) {
    if (_closeFuture != null) return _closeFuture!;
    _closed = true;
    connected = false;
    status = error ?? '連線已結束';
    _heartbeat?.cancel();
    _controlHeartbeat?.cancel();
    _deadline?.cancel();
    _connectionDeadline?.cancel();
    _changed();
    _closeFuture = _cleanup(notifyServer);
    return _closeFuture!;
  }

  Future<void> _cleanup(bool notifyServer) async {
    // Disarm gestures first, even when server/network cleanup fails.
    try {
      await NativeBridge.stop();
    } catch (_) {}
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    try {
      await _channel?.close();
    } catch (_) {}
    try {
      await _pc?.close();
      await _pc?.dispose();
    } catch (_) {}
    await _release(_screen);
    await _release(_camera);
    if (_renderersReady) {
      local.srcObject = null;
      remoteScreen.srcObject = null;
      remoteCamera.srcObject = null;
    }
    if (notifyServer) {
      try {
        await api.end(id).timeout(const Duration(seconds: 5));
      } catch (_) {
        /* lease expires server-side */
      }
    }
  }

  /// Called by the owning page AFTER it has removed its listeners/video views.
  Future<void> releaseRenderers() async {
    await close();
    if (_renderersReady) {
      _renderersReady = false;
      await local.dispose();
      await remoteScreen.dispose();
      await remoteCamera.dispose();
    }
  }
}
