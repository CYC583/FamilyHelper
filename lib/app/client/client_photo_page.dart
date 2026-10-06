// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../common/firebase_service.dart';
import '../common/photo_error.dart';
import '../common/photo_loader.dart';
import '../common/photo_reactions.dart';
import '../common/photo_thumb.dart';
import '../common/photo_viewer_page.dart';
import '../common/ui/fh_tokens.dart';

/// Family photo tab: the newest photo opens right away with hearts and a
/// short comment under it; older photos are a thumbnail album that downloads
/// only what is on screen. Opening one goes to its own page, so coming back
/// keeps the album where it was.
class ClientPhotoPage extends StatefulWidget {
  const ClientPhotoPage({
    super.key,
    required this.api,
    required this.hostId,
    required this.sharingEnabled,
    this.consent = const {},
    this.names = const {},
    this.clock = DateTime.now,
    this.saveToAlbum = saveCarePhotoToAlbum,
  });

  final FirebaseService api;
  final String hostId;
  final bool sharingEnabled;
  final Map<String, dynamic> consent;
  final Map<String, String> names;
  final DateTime Function() clock;
  final Future<bool> Function(Uint8List bytes) saveToAlbum;

  @override
  State<ClientPhotoPage> createState() => _ClientPhotoPageState();
}

class _ClientPhotoPageState extends State<ClientPhotoPage> {
  int _generation = 0;
  bool _loading = false, _loadingLatest = false, _saving = false;
  String? _error, _latestError, _saveStatus;
  List<CarePhoto> _photos = const [];
  Uint8List? _latestBytes;

  @override
  void initState() {
    super.initState();
    if (widget.sharingEnabled) unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant ClientPhotoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hostId != widget.hostId ||
        oldWidget.sharingEnabled != widget.sharingEnabled) {
      // Paused or switched: drop everything, including cached images, so a
      // download that finishes later cannot bring a photo back.
      _generation++;
      PhotoLoader.clear();
      _photos = const [];
      _latestBytes = null;
      _error = _latestError = _saveStatus = null;
      _loading = _loadingLatest = _saving = false;
      if (widget.sharingEnabled) unawaited(_load());
    }
  }

  Future<void> _load() async {
    if (!widget.sharingEnabled || _loading) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = _latestError = _saveStatus = null;
      _photos = const [];
      _latestBytes = null;
    });
    try {
      final result = await widget.api.call('listCarePhotos', {
        'hostId': widget.hostId,
      });
      final photos = CarePhoto.parseList(result['photos']);
      if (!mounted || generation != _generation || !widget.sharingEnabled) {
        return;
      }
      setState(() => _photos = photos);
      if (photos.isNotEmpty) unawaited(_loadLatest(generation));
    } catch (error) {
      if (mounted && generation == _generation && widget.sharingEnabled) {
        setState(() => _error = photoErrorMessage(error));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _loadLatest([int? generation]) async {
    final gen = generation ?? _generation;
    if (_photos.isEmpty) return;
    setState(() {
      _loadingLatest = true;
      _latestError = null;
    });
    try {
      final bytes = await PhotoLoader.load(
        widget.api,
        widget.hostId,
        _photos.first.mediaId,
      );
      if (!mounted || gen != _generation || !widget.sharingEnabled) return;
      setState(() => _latestBytes = bytes);
    } catch (error) {
      if (mounted && gen == _generation && widget.sharingEnabled) {
        setState(() => _latestError = photoOpenError(error));
      }
    } finally {
      if (mounted && gen == _generation) {
        setState(() => _loadingLatest = false);
      }
    }
  }

  Future<void> _save() async {
    final bytes = _latestBytes;
    if (!widget.sharingEnabled || bytes == null || _saving) return;
    final generation = _generation;
    setState(() {
      _saving = true;
      _saveStatus = null;
    });
    try {
      if (!await widget.saveToAlbum(bytes)) {
        throw StateError('手機沒有確認儲存成功');
      }
      if (mounted && generation == _generation && widget.sharingEnabled) {
        setState(() => _saveStatus = '已儲存到手機相簿');
      }
    } catch (error) {
      if (mounted && generation == _generation && widget.sharingEnabled) {
        setState(() => _saveStatus = '儲存失敗：${photoErrorMessage(error)}');
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _saving = false);
    }
  }

  void _open(int index) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => PhotoViewerPage(
        api: widget.api,
        hostId: widget.hostId,
        photos: _photos,
        index: index,
        names: widget.names,
        clock: widget.clock,
        saveToAlbum: widget.saveToAlbum,
      ),
    ),
  );

  String _author(CarePhoto p) => p.authorId == widget.hostId
      ? '長輩的照片'
      : '${widget.names[p.authorId] ?? '家人'}的照片';

  /// "長輩的照片・今天 10:20" — yesterday's photo is labelled 昨天.
  String _latestTitle(CarePhoto p) {
    final day = photoDayLabel(p.day, widget.clock()).split('・').first;
    return '${_author(p)}・${p.createdAt > 0 ? photoClock(p.createdAt, now: widget.clock()) : day}';
  }

  Widget _message(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 32),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 18, color: FhColors.ink),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final largeText = MediaQuery.textScalerOf(context).scale(1) >= 1.7;
    final latest = _photos.isEmpty ? null : _photos.first;
    final older = _photos.length > 1 ? _photos.sublist(1) : const <CarePhoto>[];
    final head = <Widget>[
      if (!widget.sharingEnabled)
        _message(
          photoConsentMessage(widget.consent).isEmpty
              ? '長輩尚未開啟照片分享'
              : photoConsentMessage(widget.consent),
        )
      else if (_loading)
        const Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (_error != null) ...[
        _message('照片清單暫時打不開：$_error'),
        Center(
          child: TextButton(onPressed: _load, child: const Text('再試一次')),
        ),
      ] else if (latest == null)
        _message('目前還沒有照片，長輩想分享時就會出現在這裡')
      else ...[
        Text(
          _latestTitle(latest),
          key: const Key('client-latest-title'),
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: GestureDetector(
              onTap: _latestBytes == null ? null : () => _open(0),
              child: AspectRatio(
                aspectRatio: 1,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: ColoredBox(
                    color: FhColors.brandTint,
                    child: _latestBytes != null
                        ? Image.memory(
                            _latestBytes!,
                            key: const Key('client-photo-image'),
                            fit: BoxFit.contain,
                          )
                        : Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Text(
                                    _loadingLatest
                                        ? '正在讀取照片…'
                                        : _latestError ?? '',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(fontSize: 17),
                                  ),
                                ),
                                if (_latestError != null &&
                                    _latestError != '這張照片目前已無法查看')
                                  TextButton(
                                    onPressed: _loadLatest,
                                    child: const Text('再試一次'),
                                  ),
                              ],
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        PhotoReactions(
          api: widget.api,
          hostId: widget.hostId,
          mediaId: latest.mediaId,
          names: widget.names,
        ),
        if (_latestBytes != null) ...[
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const Key('photo-save'),
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.download_outlined),
              label: Text(_saving ? '正在儲存…' : '儲存到手機相簿'),
            ),
          ),
          if (_saveStatus != null) Text(_saveStatus!, textAlign: TextAlign.end),
          const Text(
            '存進手機的副本，長輩撤銷分享後也無法收回。',
            textAlign: TextAlign.end,
            style: TextStyle(fontSize: 13, color: FhColors.inkMuted),
          ),
        ],
        if (older.isNotEmpty) ...[
          const SizedBox(height: 20),
          const Text(
            '最近照片',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
        ],
      ],
    ];
    return ColoredBox(
      color: FhColors.background,
      child: CustomScrollView(
        key: const PageStorageKey('client-photo-scroll'),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            sliver: SliverList(delegate: SliverChildListDelegate(head)),
          ),
          if (widget.sharingEnabled && _error == null && older.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: largeText ? 1 : 2,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: largeText ? 0.82 : 0.8,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => InkWell(
                    key: Key('family-photo-${older[i].mediaId}'),
                    onTap: () => _open(i + 1),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        PhotoThumb(
                          api: widget.api,
                          hostId: widget.hostId,
                          photo: older[i],
                        ),
                        const SizedBox(height: 4),
                        Flexible(
                          child: Text(
                            photoDayLabel(older[i].day, widget.clock()),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 15),
                          ),
                        ),
                      ],
                    ),
                  ),
                  childCount: older.length,
                ),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                if (widget.sharingEnabled && !_loading)
                  Center(
                    child: TextButton(
                      onPressed: _saving ? null : _load,
                      child: const Text('重新整理照片'),
                    ),
                  ),
                const Text(
                  '照片最多保留 30 天；長輩暫停或撤銷分享後，就不能再從這裡查看。',
                  style: TextStyle(fontSize: 14, color: FhColors.inkMuted),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
