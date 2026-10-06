// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../common/firebase_service.dart';
import '../common/native_bridge.dart';
import '../common/profile_page.dart';
import '../common/ui/fh_tokens.dart';
import '../common/ui/fh_format.dart';
import '../common/ui/fh_widgets.dart';

/// Where grandma's phone is, on a map with her photo. Tapping the photo
/// offers "make it ring for 10 seconds", "navigate there" and "locate again".
/// Only works while grandma has location sharing on.
class ClientLocationPage extends StatefulWidget {
  final FirebaseService api;
  final String hostId;
  final String hostName;
  final DateTime Function() clock;
  final bool showMap;
  final Future<bool> Function(double lat, double lng) navigate;
  const ClientLocationPage({
    super.key,
    required this.api,
    required this.hostId,
    this.hostName = '長輩',
    this.clock = DateTime.now,
    this.showMap = true,
    this.navigate = NativeBridge.navigateTo,
  });

  @override
  State<ClientLocationPage> createState() => _ClientLocationPageState();
}

class _ClientLocationPageState extends State<ClientLocationPage> {
  Map<String, dynamic> consent = const {}, latest = const {};
  String? avatar, status;
  bool statusError = false, busy = false, consentLoaded = false;
  final subs = <StreamSubscription<Map<String, dynamic>>>[];
  StreamSubscription<Map<String, dynamic>>? latestSub;
  final map = MapController();

  bool get on => consent['enabled'] == true && consent['status'] == 'enabled';
  LatLng? get point => latest['lat'] is num && latest['lng'] is num
      ? LatLng(
          (latest['lat'] as num).toDouble(),
          (latest['lng'] as num).toDouble(),
        )
      : null;

  @override
  void initState() {
    super.initState();
    final host = widget.hostId;
    try {
      subs.add(
        widget.api.watch('care/$host/location/consent').listen((v) {
          final was = on;
          setState(() {
            consent = v;
            consentLoaded = true;
          });
          if (on && !was) _watchLatest();
          if (!on) {
            latestSub?.cancel();
            latestSub = null;
            setState(() => latest = const {});
          }
        }, onError: (_) => setState(() => consentLoaded = true)),
      );
      subs.add(
        widget.api
            .watch('avatars/$host/$host')
            .listen(
              (v) => setState(() => avatar = v['jpegBase64'] as String?),
              onError: (_) {},
            ),
      );
    } catch (_) {
      consentLoaded = true;
    }
  }

  void _watchLatest() {
    latestSub?.cancel();
    try {
      latestSub = widget.api
          .watch('care/${widget.hostId}/location/latest')
          .listen((v) {
            setState(() => latest = v);
            final p = point;
            if (p != null && widget.showMap) {
              try {
                map.move(p, map.camera.zoom < 12 ? 16 : map.camera.zoom);
              } catch (_) {}
            }
          }, onError: (_) {});
    } catch (_) {}
  }

  @override
  void dispose() {
    for (final s in subs) {
      s.cancel();
    }
    latestSub?.cancel();
    super.dispose();
  }

  String _ago() {
    final at = latest['at'];
    if (at is! num) return '';
    final mins = widget
        .clock()
        .difference(DateTime.fromMillisecondsSinceEpoch(at.toInt()))
        .inMinutes;
    final hm = friendlyTime(at, now: widget.clock(), taipei: true);
    final rel = mins < 1
        ? '剛剛'
        : mins < 60
        ? '$mins 分鐘前'
        : '${mins ~/ 60} 小時前';
    return '$hm 更新（$rel）';
  }

  Future<void> _run(String okText, Future<void> Function() action) async {
    setState(() {
      busy = true;
      status = null;
    });
    try {
      await action();
      if (mounted) {
        setState(() {
          status = okText;
          statusError = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          status = errorMessage(e);
          statusError = true;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> locate() =>
      _run('已請${widget.hostName}的手機更新位置，約半分鐘內會更新', () async {
        await widget.api.call('requestHostUpdate', {
          'hostId': widget.hostId,
          'kind': 'locate',
        });
      });

  Future<void> ring() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('讓${widget.hostName}的手機響 10 秒？'),
        content: const Text('手機會用鬧鐘音量響 10 秒，方便找手機。對方可以按通知上的「停止」。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('讓手機響'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run('已送出，${widget.hostName}的手機會響 10 秒（手機要有網路）', () async {
      await widget.api.call('ringHostPhone', {'hostId': widget.hostId});
    });
  }

  Future<void> navigate() async {
    final p = point;
    if (p == null) return;
    try {
      await widget.navigate(p.latitude, p.longitude);
    } catch (e) {
      setState(() {
        status = '無法開啟地圖：${errorMessage(e)}';
        statusError = true;
      });
    }
  }

  void _sheet() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  AvatarCircle(
                    base64Jpeg: avatar,
                    name: widget.hostName,
                    radius: 28,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.hostName,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text(
                          _ago(),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (latest['accuracy'] is num)
                          Text(
                            '誤差約 ${latest['accuracy']} 公尺',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('location-ring'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(56),
                  backgroundColor: FhColors.danger,
                ),
                onPressed: () {
                  Navigator.pop(ctx);
                  ring();
                },
                icon: const Icon(Icons.volume_up),
                label: Text(
                  '讓手機響 10 秒',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              const SizedBox(height: 10),
              FilledButton.icon(
                key: const Key('location-navigate'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(56),
                ),
                onPressed: () {
                  Navigator.pop(ctx);
                  navigate();
                },
                icon: const Icon(Icons.directions),
                label: Text(
                  '導航過去',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                key: const Key('location-locate'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
                onPressed: () {
                  Navigator.pop(ctx);
                  locate();
                },
                icon: const Icon(Icons.my_location),
                label: Text(
                  '重新定位',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _marker() => GestureDetector(
    key: const Key('location-avatar'),
    onTap: _sheet,
    child: Container(
      padding: const EdgeInsets.all(3),
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(blurRadius: 6, color: Color(0x55000000))],
      ),
      child: AvatarCircle(
        base64Jpeg: avatar,
        name: widget.hostName,
        radius: 26,
      ),
    ),
  );

  Widget _message(String text) =>
      FhEmptyState(icon: Icons.location_off_outlined, title: text);

  @override
  Widget build(BuildContext context) {
    if (!consentLoaded) return const FhLoadingView(label: '正在讀取位置分享狀態…');
    if (!on) {
      return _message(
        consent['status'] == 'paused'
            ? '${widget.hostName}已暫停位置分享'
            : '${widget.hostName}還沒有開啟位置分享。\n請在${widget.hostName}的手機「家人設定 → 分享我的位置」陪長輩一起開啟。',
      );
    }
    final p = point;
    return Column(
      children: [
        Expanded(
          child: p == null
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _message('還沒收到${widget.hostName}手機的位置'),
                    OutlinedButton.icon(
                      onPressed: busy ? null : locate,
                      icon: const Icon(Icons.my_location),
                      label: const Text('重新定位'),
                    ),
                  ],
                )
              : !widget.showMap
              ? Center(child: _marker())
              : FlutterMap(
                  mapController: map,
                  options: MapOptions(initialCenter: p, initialZoom: 16),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.familyhelper.client',
                    ),
                    if (latest['accuracy'] is num)
                      CircleLayer(
                        circles: [
                          CircleMarker(
                            point: p,
                            radius: (latest['accuracy'] as num).toDouble(),
                            useRadiusInMeter: true,
                            color: const Color(0x33125c49),
                            borderColor: const Color(0x88125c49),
                            borderStrokeWidth: 1,
                          ),
                        ],
                      ),
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: p,
                          width: 64,
                          height: 64,
                          child: _marker(),
                        ),
                      ],
                    ),
                    const RichAttributionWidget(
                      attributions: [
                        TextSourceAttribution('OpenStreetMap contributors'),
                      ],
                    ),
                  ],
                ),
        ),
        Material(
          elevation: 6,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (p != null)
                    Row(
                      children: [
                        GestureDetector(
                          onTap: _sheet,
                          child: AvatarCircle(
                            base64Jpeg: avatar,
                            name: widget.hostName,
                            radius: 22,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '${widget.hostName}・${_ago()}',
                            key: const Key('location-updated'),
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                        IconButton(
                          tooltip: '重新定位',
                          onPressed: busy ? null : locate,
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                  if (p != null)
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: busy ? null : ring,
                            icon: const Icon(Icons.volume_up),
                            label: const Text('讓手機響'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: navigate,
                            icon: const Icon(Icons.directions),
                            label: const Text('導航'),
                          ),
                        ),
                      ],
                    ),
                  if (status != null)
                    FhStatusBanner(
                      key: const Key('location-status'),
                      tone: statusError ? FhTone.danger : FhTone.success,
                      message: status!,
                    ),
                  Text(
                    '位置約每 15 分鐘更新，可能有誤差；手機沒網路或關機時不會更新。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
