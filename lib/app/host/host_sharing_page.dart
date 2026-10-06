// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../common/firebase_service.dart';
import '../common/native_bridge.dart';
import '../common/ui/fh_tokens.dart';
import '../common/ui/fh_format.dart';
import '../common/ui/fh_widgets.dart';

/// Grandma turns on, checks or pauses one kind of sharing on her own phone:
/// "location" (where the phone is, plus "make it ring") or "usage" (minutes
/// per app). Agreeing always happens in a native dialog on this unlocked
/// phone; family cannot turn it on remotely.
class HostSharingPage extends StatefulWidget {
  final FirebaseService api;
  final String kind;
  const HostSharingPage({super.key, required this.api, required this.kind});

  @override
  State<HostSharingPage> createState() => _HostSharingPageState();
}

class _HostSharingPageState extends State<HostSharingPage>
    with WidgetsBindingObserver {
  static const disclosureVersion = 1;
  Map<String, dynamic> snap = const {};
  bool busy = false;
  String? message;

  bool get isLocation => widget.kind == 'location';
  bool get enabled => snap['enabled'] == true;
  bool get permission => isLocation
      ? snap['backgroundPermission'] == true
      : snap['permission'] == true;
  String get title => isLocation ? '分享我的位置' : '分享手機使用時間';
  String get callableName =>
      isLocation ? 'setLocationSharing' : 'setAppUsageSharing';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Coming back from system settings re-checks the permission.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      refresh();
      if (enabled) NativeBridge.locationRefresh().catchError((_) {});
    }
  }

  Future<void> refresh() async {
    try {
      final s = isLocation
          ? await NativeBridge.locationSnapshot()
          : await NativeBridge.usageSnapshot();
      if (mounted) setState(() => snap = s);
    } catch (e) {
      if (mounted) setState(() => message = errorMessage(e));
    }
  }

  Future<void> guard(Future<void> Function() action) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => message = '沒有完成：${errorMessage(e)}');
    } finally {
      await refresh();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> _locationPermission() async {
    if (!(await Permission.locationWhenInUse.request()).isGranted) {
      setState(() => message = '需要允許定位');
      return false;
    }
    if (!(await Permission.locationAlways.request()).isGranted) {
      setState(() => message = '請把位置權限改成「一律允許」，回來這頁會自動更新');
      return false;
    }
    return true;
  }

  Future<void> agree() => guard(() async {
    if (!await NativeBridge.sharingPrepareConsent(widget.kind)) return;
    if (isLocation && !await _locationPermission()) return;
    final consent = await widget.api.call(callableName, {
      'enabled': true,
      'disclosureVersion': disclosureVersion,
    });
    await NativeBridge.sharingEnable(
      widget.kind,
      widget.api.uid,
      (consent['version'] as num?)?.toInt() ?? 0,
    );
    await refresh();
    if (!isLocation && !permission) {
      setState(() => message = '最後一步：在接下來的畫面找到「FamilyHelper 長輩」，把它打開');
      await NativeBridge.openUsageAccessSettings();
    } else {
      setState(() => message = '已開啟，家人可以看到了');
    }
  });

  /// This phone stops first, so nothing more is sent even if the network
  /// call fails; then the server hides what was already shared.
  Future<void> stop() => guard(() async {
    await NativeBridge.sharingDisable(widget.kind);
    await widget.api.call(callableName, {'enabled': false});
    setState(() => message = '已關閉，家人看不到了');
  });

  String _time(Object? ms) {
    if (ms is! num) return '還沒有';
    return friendlyTime(ms, taipei: true);
  }

  @override
  Widget build(BuildContext context) {
    final today = [
      for (final a in (snap['today'] as List? ?? const []))
        if (a is Map) '${a['name']}：${a['minutes']} 分鐘',
    ];
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            isLocation
                ? '家人可以在地圖上看到你的手機大約在哪裡，也可以讓手機響 10 秒幫你找手機。'
                : '家人可以看到你每個 App 用了多久，只有名稱和分鐘數。',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 20),
          Text(
            enabled ? (permission ? '分享中 ✓' : '已同意，但還差一個系統設定') : '沒有分享',
            key: const Key('sharing-state'),
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: enabled && permission ? FhColors.brand : FhColors.inkMuted,
            ),
          ),
          if (enabled && !permission) ...[
            const SizedBox(height: 8),
            Text(
              isLocation
                  ? '位置權限要選「一律允許」，關掉 App 時家人才看得到。'
                  : '要在系統設定裡打開「FamilyHelper 長輩」的使用情形存取權。',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: FhColors.danger),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(64),
              ),
              onPressed: busy
                  ? null
                  : () => isLocation
                        ? guard(() async => _locationPermission())
                        : NativeBridge.openUsageAccessSettings(),
              child: Text('去設定', style: Theme.of(context).textTheme.labelLarge),
            ),
          ],
          if (enabled && isLocation)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '上次送出位置：${_time(snap['lastSentAt'])}${snap['lastError'] is String ? '（${snap['lastError']}）' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (enabled && !isLocation && today.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('今天用最久的：', style: Theme.of(context).textTheme.bodyMedium),
            for (final line in today)
              Text(line, style: Theme.of(context).textTheme.bodyMedium),
          ],
          const SizedBox(height: 24),
          if (!enabled)
            FilledButton(
              key: const Key('sharing-agree'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(80),
                backgroundColor: FhColors.brand,
              ),
              onPressed: busy ? null : agree,
              child: Text(
                '看說明並開啟',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            )
          else
            OutlinedButton(
              key: const Key('sharing-stop'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(72),
              ),
              onPressed: busy ? null : stop,
              child: Text(
                '關閉分享',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: FhStatusBanner(
                key: const Key('sharing-message'),
                message: message!,
              ),
            ),
        ],
      ),
    );
  }
}
