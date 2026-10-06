// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/firebase_service.dart';
import 'photo_camera_service.dart';
import 'photo_error.dart';
import '../common/ui/fh_tokens.dart';

/// A single, elder-initiated camera session. No image leaves memory until the
/// elder confirms sharing, and the server checks consent again at upload time.
class PhotoCapturePage extends StatefulWidget {
  const PhotoCapturePage({
    super.key,
    required this.api,
    required this.cameraPort,
    required this.consentEnabled,
  });

  final FirebaseService api;
  final PhotoCameraPort cameraPort;
  final bool consentEnabled;

  @override
  State<PhotoCapturePage> createState() => _PhotoCapturePageState();
}

class _PhotoCapturePageState extends State<PhotoCapturePage>
    with WidgetsBindingObserver {
  PhotoCameraSession? _session;
  Uint8List? _photo;
  String? _error;
  String? _opId;
  bool _front = true;
  bool _busy = false;
  bool _consentEnabled = false;
  bool _failed = false, _flash = false;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    _consentEnabled = widget.consentEnabled;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openCamera());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The Android permission sheet may only make the activity inactive.
    if (state != AppLifecycleState.paused &&
        state != AppLifecycleState.detached) {
      return;
    }
    _revision++;
    final old = _session;
    _session = null;
    if (old != null) unawaited(old.close());
    if (mounted) {
      setState(() {
        _busy = false;
        _error = '相機已暫停，請按「重新開啟相機」。';
      });
    }
  }

  Future<void> _openCamera() async {
    if (!mounted || _busy) return;
    final revision = ++_revision;
    final old = _session;
    setState(() {
      _session = null;
      _photo = null;
      _opId = null;
      _error = null;
      _failed = false;
      _busy = true;
    });
    try {
      if (old != null) await old.close();
      if (!mounted || revision != _revision) return;
      final opened = await widget.cameraPort.open(front: _front);
      if (!mounted || revision != _revision) {
        await opened.close();
        return;
      }
      setState(() {
        _session = opened;
        _busy = false;
      });
    } catch (error) {
      if (mounted && revision == _revision) {
        setState(() {
          _busy = false;
          _error = errorMessage(error);
        });
      }
    }
  }

  Future<void> _flip() async {
    if (_busy) return;
    setState(() => _front = !_front);
    await _openCamera();
  }

  Future<void> _takePhoto() async {
    final session = _session;
    if (_busy || session == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await session.captureSquare(mirror: _front);
      if (!mounted || _session != session) return;
      // A short flash and buzz so it is obvious the photo was taken.
      unawaited(HapticFeedback.mediumImpact().catchError((_) {}));
      setState(() => _flash = true);
      Timer(const Duration(milliseconds: 180), () {
        if (mounted) setState(() => _flash = false);
      });
      final random = Random.secure();
      setState(() {
        _photo = bytes;
        _opId = base64UrlEncode(
          List<int>.generate(18, (_) => random.nextInt(256)),
        ).replaceAll('=', '');
        _session = null;
        _busy = false;
      });
      await session.close();
    } catch (error) {
      if (mounted && _session == session) {
        setState(() {
          _busy = false;
          _error = errorMessage(error);
        });
      }
    }
  }

  Future<void> _share() async {
    final photo = _photo;
    final opId = _opId;
    if (_busy || photo == null || opId == null) return;
    if (!_consentEnabled) {
      final allowed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: const Text('同意分享照片？'),
          content: const Text(
            '同意後，已配對的家人可以看這張照片，也能重新看到尚未到期、先前暫停分享的照片。您可在照片頁再次暫停或撤銷；照片最多保留 30 天。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('先不要'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('同意並分享'),
            ),
          ],
        ),
      );
      if (allowed != true || !mounted) return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _failed = false;
    });
    try {
      if (!_consentEnabled) {
        final consent = await widget.api.call('setPhotoConsent', {
          'enabled': true,
        });
        if (consent['enabled'] != true) throw StateError('照片分享同意尚未生效');
        _consentEnabled = true;
      }
      // Keep this operation ID and the photo in memory for a safe retry.
      final uploaded = await widget.api.call('uploadCarePhoto', {
        'hostId': widget.api.uid,
        'opId': opId,
        'jpegBase64': base64Encode(photo),
      });
      if (uploaded['mediaId'] is! String ||
          (uploaded['mediaId'] as String).isEmpty) {
        throw StateError('伺服器未確認照片已儲存，請重試');
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _failed = true;
          _error = '照片尚未分享，照片還在，按「再試一次」：${photoErrorMessage(error)}';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _revision++;
    final old = _session;
    if (old != null) unawaited(old.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final photo = _photo;
    final largeText = MediaQuery.textScalerOf(context).scale(1) >= 1.7;
    return Scaffold(
      backgroundColor: FhColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            children: [
              Row(
                children: [
                  TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () => Navigator.pop(context, false),
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('返回'),
                  ),
                  const Spacer(),
                  const Text(
                    '拍一張給家人',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              Text(
                photo != null ? '這張要給家人看嗎？' : '對好畫面，按下面拍照',
                key: const Key('capture-prompt'),
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (photo == null)
                Text(
                  _front ? '現在：拍自己' : '現在：拍前面',
                  style: const TextStyle(fontSize: 17),
                ),
              const SizedBox(height: 8),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, limits) {
                    final side = min(limits.maxWidth, limits.maxHeight);
                    return Center(
                      child: SizedBox.square(
                        dimension: side,
                        child: ClipRRect(
                          key: const Key('host-square-camera'),
                          borderRadius: BorderRadius.circular(20),
                          child: ColoredBox(
                            color: FhColors.ink,
                            child: _flash
                                ? const ColoredBox(color: Colors.white)
                                : photo != null
                                ? Image.memory(photo, fit: BoxFit.cover)
                                : _session != null
                                ? _session!.preview(mirror: _front)
                                : Center(
                                    child: Text(
                                      _busy ? '正在開啟鏡頭…' : _error ?? '相機尚未開啟',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 20,
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: FhColors.danger, fontSize: 17),
                ),
              ],
              const SizedBox(height: 8),
              if (largeText) ...[
                _secondaryAction(photo),
                const SizedBox(height: 8),
                _primaryAction(photo),
              ] else
                Row(
                  children: [
                    Expanded(child: _secondaryAction(photo)),
                    const SizedBox(width: 8),
                    Expanded(flex: 2, child: _primaryAction(photo)),
                  ],
                ),
              const SizedBox(height: 6),
              Text(
                _busy && photo != null
                    ? '正在分享，請稍等'
                    : photo == null
                    ? '拍下後先給你看，不會自動送出。'
                    : '還沒送出；按「分享給家人」才會給家人看。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: _busy && photo != null ? 20 : 16,
                  color: FhColors.inkMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _secondaryAction(Uint8List? photo) => OutlinedButton(
    onPressed: _busy
        ? null
        : photo != null
        ? _openCamera
        : _flip,
    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(64)),
    child: Text(
      photo != null
          ? '重拍'
          : _front
          ? '拍前面'
          : '拍自己',
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 18),
    ),
  );

  Widget _primaryAction(Uint8List? photo) => FilledButton(
    onPressed: _busy
        ? null
        : photo != null
        ? _share
        : _session == null
        ? _openCamera
        : _takePhoto,
    style: FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(76),
      backgroundColor: FhColors.brand,
    ),
    child: Text(
      photo != null
          ? (_failed ? '再試一次' : '分享給家人')
          : _session == null
          ? '重新開啟相機'
          : '拍照',
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
    ),
  );
}
