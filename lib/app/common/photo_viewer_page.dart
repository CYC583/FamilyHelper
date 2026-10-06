// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';
import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import 'firebase_service.dart';
import 'native_bridge.dart';
import 'photo_error.dart';
import 'photo_loader.dart';
import 'photo_reactions.dart';
import 'ui/fh_tokens.dart';

/// Shown when a photo cannot be displayed. Expired or withdrawn photos are
/// told apart from a temporary failure.
String photoOpenError(Object e) {
  if (e is FirebaseFunctionsException &&
      e.message != 'NOT_FOUND' &&
      const {
        'not-found',
        'failed-precondition',
        'permission-denied',
      }.contains(e.code)) {
    return '這張照片目前已無法查看';
  }
  return '這張照片暫時打不開（${photoErrorMessage(e)}）';
}

/// One photo full screen with its hearts and comments. A big「返回」button
/// and「上一張／下一張」buttons mean nobody has to learn swipe gestures.
class PhotoViewerPage extends StatefulWidget {
  final FirebaseService api;
  final String hostId;
  final List<CarePhoto> photos;
  final int index;
  final Map<String, String> names;
  final bool isHost;
  final DateTime Function() clock;
  final Future<bool> Function(Uint8List bytes)? saveToAlbum;
  const PhotoViewerPage({
    super.key,
    required this.api,
    required this.hostId,
    required this.photos,
    required this.index,
    this.names = const {},
    this.isHost = false,
    this.clock = DateTime.now,
    this.saveToAlbum,
  });

  @override
  State<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<PhotoViewerPage> {
  late int index = widget.index;
  Uint8List? bytes;
  String? error, saveStatus;
  bool loading = false, saving = false, sharing = true;
  int _generation = 0;
  StreamSubscription<Map<String, dynamic>>? _consentSub;

  CarePhoto get photo => widget.photos[index];

  @override
  void initState() {
    super.initState();
    try {
      _consentSub = widget.api.family(widget.hostId).listen((family) {
        final on = asMap(family['photoConsent'])['enabled'] == true;
        if (!mounted || on == sharing) return;
        if (!on) PhotoLoader.clear();
        setState(() {
          sharing = on;
          if (!on) {
            _generation++;
            bytes = null;
          }
        });
        if (on) _load();
      }, onError: (_) {});
    } catch (_) {}
    _load();
  }

  @override
  void dispose() {
    _consentSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final id = photo.mediaId;
    setState(() {
      bytes = PhotoLoader.cached(widget.hostId, id);
      error = null;
      saveStatus = null;
      loading = bytes == null;
    });
    if (bytes != null) return;
    try {
      final loaded = await PhotoLoader.load(widget.api, widget.hostId, id);
      if (!mounted || generation != _generation || !sharing) return;
      setState(() => bytes = loaded);
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() => error = photoOpenError(e));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => loading = false);
      }
    }
  }

  void _go(int next) {
    if (next < 0 || next >= widget.photos.length) return;
    setState(() => index = next);
    _load();
  }

  Future<void> _save() async {
    final data = bytes, save = widget.saveToAlbum;
    if (data == null || save == null || saving) return;
    setState(() {
      saving = true;
      saveStatus = null;
    });
    try {
      if (!await save(data)) throw StateError('手機沒有確認儲存成功');
      if (mounted) setState(() => saveStatus = '已儲存到手機相簿');
    } catch (e) {
      if (mounted) {
        setState(() => saveStatus = '儲存失敗：${photoErrorMessage(e)}');
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final big = widget.isHost;
    final label = photoDayLabel(photo.day, widget.clock());
    return Scaffold(
      backgroundColor: FhColors.background,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leadingWidth: 120,
        leading: TextButton.icon(
          key: const Key('photo-viewer-back'),
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back, size: 28),
          label: Text('返回', style: TextStyle(fontSize: big ? 22 : 18)),
        ),
        title: Text(label, style: TextStyle(fontSize: big ? 22 : 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (!sharing)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Text(
                widget.isHost ? '照片分享已暫停' : '長輩已暫停照片分享',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: big ? 22 : 18),
              ),
            )
          else ...[
            AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: ColoredBox(
                  color: FhColors.brandTint,
                  child: bytes != null
                      ? InteractiveViewer(
                          maxScale: 4,
                          child: Image.memory(
                            bytes!,
                            key: const Key('photo-viewer-image'),
                            fit: BoxFit.contain,
                          ),
                        )
                      : Center(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  loading ? '正在讀取照片…' : error ?? '',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: big ? 22 : 17),
                                ),
                                if (error != null && error != '這張照片目前已無法查看')
                                  TextButton(
                                    onPressed: _load,
                                    child: const Text('再試一次'),
                                  ),
                              ],
                            ),
                          ),
                        ),
                ),
              ),
            ),
            if (!big)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('可以用兩指放大', style: TextStyle(fontSize: 14)),
              ),
            if (widget.photos.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('photo-viewer-newer'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: Size.fromHeight(big ? 64 : 48),
                        ),
                        onPressed: index > 0 ? () => _go(index - 1) : null,
                        icon: const Icon(Icons.chevron_left),
                        label: Text(
                          '上一張',
                          style: TextStyle(fontSize: big ? 20 : 16),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('photo-viewer-older'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: Size.fromHeight(big ? 64 : 48),
                        ),
                        onPressed: index < widget.photos.length - 1
                            ? () => _go(index + 1)
                            : null,
                        icon: const Icon(Icons.chevron_right),
                        label: Text(
                          '下一張',
                          style: TextStyle(fontSize: big ? 20 : 16),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            PhotoReactions(
              api: widget.api,
              hostId: widget.hostId,
              mediaId: photo.mediaId,
              names: widget.names,
              large: big,
              allowComment: !widget.isHost,
            ),
            if (widget.saveToAlbum != null && bytes != null) ...[
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('photo-save'),
                  onPressed: saving ? null : _save,
                  icon: const Icon(Icons.download_outlined),
                  label: Text(saving ? '正在儲存…' : '儲存到手機相簿'),
                ),
              ),
              if (saveStatus != null) Text(saveStatus!),
              const Text(
                '存進手機的副本，長輩撤銷分享後也無法收回。',
                style: TextStyle(fontSize: 14, color: FhColors.inkMuted),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// Default album saver for the family app.
Future<bool> saveCarePhotoToAlbum(Uint8List bytes) =>
    NativeBridge.savePhotoToAlbum(bytes);
