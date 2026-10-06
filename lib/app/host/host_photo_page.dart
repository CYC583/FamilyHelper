// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../common/firebase_service.dart';
import '../common/photo_loader.dart';
import '../common/photo_reactions.dart';
import '../common/photo_thumb.dart';
import '../common/photo_viewer_page.dart';
import 'photo_camera_service.dart';
import 'photo_capture_page.dart';
import 'photo_error.dart';
import '../common/ui/fh_tokens.dart';
import '../common/ui/fh_widgets.dart';

String _taipeiTodayKey(DateTime now) => now
    .toUtc()
    .add(const Duration(hours: 8))
    .toIso8601String()
    .substring(0, 10);

/// Grandma's photo tab. Before today's photo: one big "拍一張給家人". After:
/// today's photo is the main thing, with family hearts and comments right
/// under it. Older photos open from「看看以前的照片」. One photo a day.
class HostPhotoPage extends StatefulWidget {
  const HostPhotoPage({
    super.key,
    required this.api,
    this.cameraPort,
    this.clock = DateTime.now,
  });

  final FirebaseService api;
  final PhotoCameraPort? cameraPort;
  final DateTime Function() clock;

  @override
  State<HostPhotoPage> createState() => _HostPhotoPageState();
}

class _HostPhotoPageState extends State<HostPhotoPage> {
  StreamSubscription<Map<String, dynamic>>? _familySub;
  Map<String, dynamic> _consent = const {};
  Map<String, String> _names = const {};
  bool _loading = false;
  bool _changingConsent = false;
  bool _loadFailed = false;
  bool _statusError = true;
  String? _status;
  List<CarePhoto> _photos = const [];
  CarePhoto? _today;
  Uint8List? _todayBytes;

  bool get _consentEnabled => _consent['enabled'] == true;

  @override
  void initState() {
    super.initState();
    _familySub = widget.api
        .family(widget.api.uid)
        .listen(
          (family) {
            if (!mounted) return;
            final consent = asMap(family['photoConsent']);
            final wasOn = _consentEnabled;
            setState(() {
              _consent = consent;
              _names = {
                for (final e in asMap(family['members']).entries)
                  e.key: asMap(e.value)['name'] as String? ?? '家人',
              };
            });
            if (wasOn && !_consentEnabled) {
              PhotoLoader.clear();
              setState(() {
                _photos = const [];
                _today = null;
                _todayBytes = null;
              });
            }
            if (!wasOn && _consentEnabled) unawaited(_load());
          },
          onError: (Object error) {
            if (mounted) {
              setState(() {
                _status = '照片分享狀態無法讀取：${errorMessage(error)}';
                _statusError = true;
              });
            }
          },
        );
    // An undeployed service must report an error, never sample data.
    unawaited(_load());
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final result = await widget.api.call('listCarePhotos', {
        'hostId': widget.api.uid,
      });
      final photos = CarePhoto.parseList(result['photos']);
      final todayKey = _taipeiTodayKey(widget.clock());
      final today = photos.where((p) => p.day == todayKey).firstOrNull;
      Uint8List? bytes;
      if (today != null) {
        // Today's photo still counts as shared even if the image itself
        // cannot be fetched right now; never offer a second photo for today.
        try {
          bytes = await PhotoLoader.load(
            widget.api,
            widget.api.uid,
            today.mediaId,
          );
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _photos = photos;
        _today = today;
        _todayBytes = bytes;
        if (_statusError) _status = null;
        _loadFailed = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          final reason = photoErrorMessage(error);
          if (_status == '照片已分享，家人可以看了') {
            _status = '照片已分享，家人可以看了；但照片暫時無法載入：$reason';
            _statusError = false;
          } else {
            _status = '照片尚無法載入：$reason';
            _statusError = true;
          }
          _loadFailed = true;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openCamera() async {
    final shared = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PhotoCapturePage(
          api: widget.api,
          cameraPort: widget.cameraPort ?? const WebRtcPhotoCameraPort(),
          consentEnabled: _consentEnabled,
        ),
      ),
    );
    if (!mounted || shared != true) return;
    setState(() {
      _consent = {..._consent, 'enabled': true};
      _status = '照片已分享，家人可以看了';
      _statusError = false;
    });
    unawaited(_load());
  }

  void _openViewer(int index) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => PhotoViewerPage(
        api: widget.api,
        hostId: widget.api.uid,
        photos: _photos,
        index: index,
        names: _names,
        isHost: true,
        clock: widget.clock,
      ),
    ),
  );

  void _openHistory() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => HostPhotoHistoryPage(
        api: widget.api,
        photos: _photos,
        names: _names,
        clock: widget.clock,
      ),
    ),
  );

  Future<void> _setConsent(bool enabled) async {
    if (_changingConsent) return;
    setState(() => _changingConsent = true);
    try {
      final response = await widget.api.call('setPhotoConsent', {
        'enabled': enabled,
      });
      if (response['enabled'] != enabled) {
        throw StateError('伺服器未確認，請重試');
      }
      if (!enabled) PhotoLoader.clear();
      if (mounted) {
        setState(() {
          _consent = asMap(response).isEmpty
              ? {..._consent, 'enabled': enabled}
              : asMap(response);
          if (!enabled) {
            _today = null;
            _todayBytes = null;
            _photos = const [];
          }
          _status = enabled ? '已恢復分享，家人可以看照片了' : '已暫停分享；家人目前無法查看照片。';
          _statusError = false;
          _loadFailed = false;
        });
      }
      if (enabled) unawaited(_load());
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = '${enabled ? '恢復' : '暫停'}失敗：${photoErrorMessage(error)}';
          _statusError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _changingConsent = false);
    }
  }

  Future<void> _resume() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢復照片分享？'),
        content: const Text('恢復後，家人可以看到你之後分享的照片，也會重新看到還沒到期（30 天內）的舊照片。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('先不要'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('恢復分享'),
          ),
        ],
      ),
    );
    if (ok == true) await _setConsent(true);
  }

  Future<void> _revokeSharing() async {
    if (_changingConsent) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('撤銷照片分享？'),
        content: const Text('撤銷後，家人不能再看先前分享的照片；雲端檔案會由後台清理。以後想分享，需重新同意。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('先不要'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('確認撤銷'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _changingConsent = true);
    try {
      final response = await widget.api.call('revokePhotoConsent');
      if (response['enabled'] != false) throw StateError('伺服器未確認撤銷，請重試');
      PhotoLoader.clear();
      if (mounted) {
        setState(() {
          _consent = asMap(response).isEmpty
              ? {'enabled': false, 'revokedAt': 0}
              : asMap(response);
          _today = null;
          _todayBytes = null;
          _photos = const [];
          _status = '已撤銷分享；家人不能再看先前照片。';
          _statusError = false;
          _loadFailed = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = '撤銷失敗：${photoErrorMessage(error)}';
          _statusError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _changingConsent = false);
    }
  }

  Future<void> _manage() async {
    final revoked = _consent['revokedAt'] is num;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          children: [
            Text(
              _consentEnabled
                  ? '現在：家人看得到你分享的照片'
                  : revoked
                  ? '現在：已撤銷，下次拍照分享時會再問你'
                  : _consent.isEmpty
                  ? '現在：還沒有分享，拍照時會先問你'
                  : '現在：已暫停，家人看不到照片',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            if (_consentEnabled)
              _sheetButton(context, 'pause', '暫停分享', '暫時不讓家人看照片'),
            if (!_consentEnabled && _consent.isNotEmpty && !revoked)
              _sheetButton(context, 'resume', '恢復分享', '30 天內的舊照片也會重新給家人看'),
            if (_consent.isNotEmpty && !revoked)
              _sheetButton(context, 'revoke', '撤銷分享', '家人不能再看以前的照片'),
            Text('照片最多保留 30 天。', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
    switch (action) {
      case 'pause':
        await _setConsent(false);
      case 'resume':
        await _resume();
      case 'revoke':
        await _revokeSharing();
    }
  }

  Widget _sheetButton(
    BuildContext context,
    String value,
    String label,
    String hint,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: OutlinedButton(
      key: Key('photo-$value'),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(64),
        alignment: Alignment.centerLeft,
      ),
      onPressed: () => Navigator.pop(context, value),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          Text(hint, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    ),
  );

  @override
  void dispose() {
    _familySub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final today = _today;
    final todayIndex = today == null ? -1 : _photos.indexOf(today);
    final earlier = _photos.where((p) => p != today).toList();
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '照片',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              TextButton.icon(
                key: const Key('host-photo-manage'),
                onPressed: _changingConsent ? null : _manage,
                icon: Icon(
                  _consentEnabled ? Icons.people : Icons.lock_outline,
                  size: 24,
                ),
                label: Text(
                  _consentEnabled ? '分享中・管理' : '未分享・管理',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (today == null) ...[
            Text('今天想分享什麼？', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('host-open-camera'),
              onPressed: _openCamera,
              icon: const Icon(Icons.photo_camera, size: 36),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(96),
                backgroundColor: FhColors.brand,
                foregroundColor: Colors.white,
              ),
              label: Text(
                '拍一張給家人',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '拍自己、花草或今天的午餐都可以',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            if (!_consentEnabled)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '分享前會先問你；沒有同意，照片不會給家人。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ] else ...[
            Text(
              photoDayLabel(today.day, widget.clock()),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Semantics(
              button: true,
              label: '今天的照片，點一下放大',
              child: GestureDetector(
                onTap: () => _openViewer(todayIndex),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: ColoredBox(
                      color: FhColors.brandTint,
                      child: _todayBytes != null
                          ? Image.memory(
                              _todayBytes!,
                              key: const Key('host-today-photo'),
                              fit: BoxFit.contain,
                            )
                          : Center(
                              child: Text(
                                '照片暫時打不開',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text('點一下可以放大', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Text(
              '今天已分享給家人 ✓',
              key: const Key('host-photo-shared'),
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: FhColors.brand),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
              ),
              child: PhotoReactions(
                api: widget.api,
                hostId: widget.api.uid,
                mediaId: today.mediaId,
                names: _names,
                large: true,
                allowComment: false,
              ),
            ),
          ],
          if (_status != null) ...[
            const SizedBox(height: 12),
            FhStatusBanner(
              key: const Key('host-photo-status'),
              tone: _statusError ? FhTone.danger : FhTone.success,
              message: _status!,
            ),
            if (_loadFailed)
              TextButton(
                onPressed: _loading ? null : _load,
                child: Text(
                  '再試一次',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
          ],
          if (_loading && _photos.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: FhStatusBanner(message: '正在讀取照片…'),
            ),
          if (today == null && earlier.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('最近分享的照片', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Card(
              child: InkWell(
                key: const Key('host-latest-earlier'),
                onTap: () => _openViewer(_photos.indexOf(earlier.first)),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 88,
                        child: PhotoThumb(
                          api: widget.api,
                          hostId: widget.api.uid,
                          photo: earlier.first,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          photoDayLabel(earlier.first.day, widget.clock()),
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                      Text('查看', style: Theme.of(context).textTheme.bodyMedium),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                ),
              ),
            ),
          ],
          if (_photos.isNotEmpty) ...[
            const SizedBox(height: 16),
            OutlinedButton.icon(
              key: const Key('host-photo-history'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(64),
              ),
              onPressed: _openHistory,
              icon: const Icon(Icons.photo_library_outlined, size: 28),
              label: Text(
                '看看以前的照片',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Grandma's look back: one big thumbnail per row with the full date. Only
/// photos that can still be viewed are listed; days without photos are not.
class HostPhotoHistoryPage extends StatelessWidget {
  final FirebaseService api;
  final List<CarePhoto> photos;
  final Map<String, String> names;
  final DateTime Function() clock;
  const HostPhotoHistoryPage({
    super.key,
    required this.api,
    required this.photos,
    required this.names,
    this.clock = DateTime.now,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: FhColors.background,
    appBar: AppBar(
      automaticallyImplyLeading: false,
      leadingWidth: 120,
      leading: TextButton.icon(
        onPressed: () => Navigator.of(context).pop(),
        icon: const Icon(Icons.arrow_back, size: 28),
        label: Text('返回', style: Theme.of(context).textTheme.labelLarge),
      ),
      title: Text('以前的照片', style: Theme.of(context).textTheme.titleLarge),
    ),
    body: photos.isEmpty
        ? const FhEmptyState(icon: Icons.photo_library_outlined, title: '還沒有照片')
        : ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: photos.length,
            itemBuilder: (context, i) => Card(
              key: Key('host-history-${photos[i].mediaId}'),
              child: InkWell(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PhotoViewerPage(
                      api: api,
                      hostId: api.uid,
                      photos: photos,
                      index: i,
                      names: names,
                      isHost: true,
                      clock: clock,
                    ),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 120,
                        child: PhotoThumb(
                          api: api,
                          hostId: api.uid,
                          photo: photos[i],
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          photoDayLabel(photos[i].day, clock()),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      const Icon(Icons.chevron_right, size: 32),
                    ],
                  ),
                ),
              ),
            ),
          ),
  );
}
