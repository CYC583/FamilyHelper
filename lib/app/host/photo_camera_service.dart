// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'photo_processing.dart';

/// The camera is opened only after the elder taps the photo entry point.
/// Captured bytes stay in memory until the caller explicitly chooses what to do.
abstract class PhotoCameraPort {
  Future<PhotoCameraSession> open({required bool front});
}

abstract class PhotoCameraSession {
  Widget preview({required bool mirror});
  Future<Uint8List> captureSquare({required bool mirror});
  Future<void> close();
}

class WebRtcPhotoCameraPort implements PhotoCameraPort {
  const WebRtcPhotoCameraPort();

  @override
  Future<PhotoCameraSession> open({required bool front}) async {
    if (!await Permission.camera.request().isGranted) {
      throw StateError('請允許相機權限，再試一次');
    }
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    try {
      final stream = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {
          'facingMode': front ? 'user' : 'environment',
          'width': 960,
          'height': 960,
        },
      });
      try {
        if (stream.getVideoTracks().isEmpty) {
          throw StateError('找不到可使用的鏡頭');
        }
        await renderer.setSrcObject(stream: stream);
        return _WebRtcPhotoCameraSession(renderer, stream);
      } catch (_) {
        for (final track in stream.getTracks()) {
          track.stop();
        }
        await stream.dispose();
        rethrow;
      }
    } catch (_) {
      await renderer.dispose();
      rethrow;
    }
  }
}

class _WebRtcPhotoCameraSession implements PhotoCameraSession {
  _WebRtcPhotoCameraSession(this._renderer, this._stream);

  final RTCVideoRenderer _renderer;
  final MediaStream _stream;
  bool _closed = false;

  @override
  Widget preview({required bool mirror}) => RTCVideoView(
    _renderer,
    mirror: mirror,
    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
  );

  @override
  Future<Uint8List> captureSquare({required bool mirror}) async {
    if (_closed) throw StateError('相機已關閉，請重新開啟');
    final tracks = _stream.getVideoTracks();
    if (tracks.isEmpty) throw StateError('找不到可拍照的鏡頭');
    // flutter_webrtc 1.6.2 writes captureFrame.png to the app cache first.
    // Remove it even when decoding fails; previews must not leave a photo file.
    final cache = await getTemporaryDirectory();
    final frameFile = File('${cache.path}/captureFrame.png');
    try {
      final frame = await tracks.first.captureFrame();
      final square = await cropSquarePng(frame.asUint8List(), mirror: mirror);
      return await compute(preparePhotoForSharing, square);
    } finally {
      try {
        if (await frameFile.exists()) await frameFile.delete();
      } catch (_) {
        throw StateError('暫存照片無法刪除；請清除 App 快取後再拍照');
      }
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _renderer.setSrcObject(stream: null);
    for (final track in _stream.getTracks()) {
      track.stop();
    }
    await _stream.dispose();
    await _renderer.dispose();
  }
}

/// Center-crop to the same square shown in the 1:1 finder. Selfies keep the
/// familiar mirrored composition in the captured preview.
Future<Uint8List> cropSquarePng(
  Uint8List source, {
  required bool mirror,
}) async {
  final codec = await ui.instantiateImageCodec(source);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  try {
    final side = image.width < image.height ? image.width : image.height;
    final left = (image.width - side) / 2;
    final top = (image.height - side) / 2;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    if (mirror) {
      canvas.translate(side.toDouble(), 0);
      canvas.scale(-1, 1);
    }
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(left, top, side.toDouble(), side.toDouble()),
      ui.Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
      ui.Paint(),
    );
    final picture = recorder.endRecording();
    try {
      final square = await picture.toImage(side, side);
      try {
        final data = await square.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) throw StateError('照片處理失敗，請重拍');
        return data.buffer.asUint8List();
      } finally {
        square.dispose();
      }
    } finally {
      picture.dispose();
    }
  } finally {
    image.dispose();
    codec.dispose();
  }
}
