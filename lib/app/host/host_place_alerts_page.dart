// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../common/firebase_service.dart';
import '../common/native_bridge.dart';
import '../common/ui/fh_tokens.dart';

/// Done on grandma's phone with her, in three steps: agree → save places →
/// confirm detection is really active. Coordinates never leave the phone.
class HostPlaceAlertsPage extends StatefulWidget {
  final FirebaseService api;
  const HostPlaceAlertsPage({super.key, required this.api});

  @override
  State<HostPlaceAlertsPage> createState() => _HostPlaceAlertsPageState();
}

class _HostPlaceAlertsPageState extends State<HostPlaceAlertsPage>
    with WidgetsBindingObserver {
  static const disclosureVersion = 1;
  static const placeNames = ['工作地點', '店裡', '活動中心', '市場', '公園', '朋友家'];
  Map<String, dynamic> snap = const {};
  bool busy = false;
  String? message;
  Timer? poll;

  bool get enabled => snap['enabled'] == true;
  bool get background => snap['backgroundPermission'] == true;
  bool get homeSet => snap['homeSet'] == true;
  bool get workSet => snap['workSet'] == true;
  bool get registered => snap['registered'] == true;
  String get workName => snap['workName'] as String? ?? '工作地點';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refresh();
    // Geofence registration finishes asynchronously; re-check for a moment.
    poll = Timer.periodic(const Duration(seconds: 3), (t) {
      if (t.tick > 10) t.cancel();
      refresh();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      NativeBridge.placeRegister().catchError((_) {});
      refresh();
    }
  }

  @override
  void dispose() {
    poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> refresh() async {
    try {
      final s = await NativeBridge.placeSnapshot();
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

  Future<bool> _permissions() async {
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

  Future<void> _syncServer() async {
    final consent = await widget.api.call('setPlaceAlerts', {
      'enabled': true,
      'disclosureVersion': disclosureVersion,
      'homeSet': homeSet,
      'workSet': workSet,
      'workName': workName,
    });
    await NativeBridge.placeEnable(
      widget.api.uid,
      (consent['version'] as num?)?.toInt() ?? 0,
    );
  }

  Future<void> agree() => guard(() async {
    if (!await NativeBridge.placePrepareConsent()) return;
    if (!await _permissions()) return;
    await _syncServer();
  });

  Future<void> setHere(String kind) => guard(() async {
    if (!await _permissions()) return;
    if (!await NativeBridge.placeSetHere(kind)) {
      setState(() => message = '抓不到目前位置，請到窗邊或戶外再試一次');
      return;
    }
    await refresh();
    await _syncServer();
    setState(() => message = kind == 'home' ? '已把這裡設成家' : '已把這裡設成$workName');
  });

  Future<void> rename(String name) => guard(() async {
    await NativeBridge.placeSetWorkName(name);
    await refresh();
    if (enabled) await _syncServer();
  });

  Future<void> stop({required bool revoke}) => guard(() async {
    await NativeBridge.placeDisable(forget: revoke);
    await widget.api.call('setPlaceAlerts', {
      'enabled': false,
      'revoke': revoke,
    });
    setState(() => message = revoke ? '已關閉並刪除地點' : '已暫停');
  });

  String get detection {
    if (!enabled) return '尚未同意';
    if (!background) return '背景定位尚未允許';
    if (!homeSet && !workSet) return '尚未設定家';
    if (!registered) return '正在設定偵測…';
    return '偵測設定完成';
  }

  Widget step(int n, String title, bool done, List<Widget> body) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: done ? FhColors.brand : FhColors.outline,
                child: done
                    ? const Icon(Icons.check, color: Colors.white)
                    : Text('$n', style: const TextStyle(fontSize: 20)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...body,
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    const body = TextStyle(fontSize: 20);
    return Scaffold(
      appBar: AppBar(title: const Text('出門到家通知')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('離開或到達家、第二個地點時通知家人。只傳地點名稱和時間，不傳位置座標。', style: body),
          if (message != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                message!,
                style: body.copyWith(color: FhColors.brand),
              ),
            ),
          step(1, '同意分享', enabled && background, [
            if (!enabled)
              SizedBox(
                height: 60,
                child: FilledButton(
                  key: const Key('place-agree'),
                  onPressed: busy ? null : agree,
                  child: const Text('看說明並同意', style: body),
                ),
              )
            else if (!background)
              SizedBox(
                height: 60,
                child: OutlinedButton(
                  onPressed: busy
                      ? null
                      : () => guard(() async {
                          await _permissions();
                        }),
                  child: const Text('位置權限改成「一律允許」', style: body),
                ),
              )
            else
              const Text('已同意', style: body),
          ]),
          step(2, '設定地點', homeSet && workSet, [
            for (final (kind, label, set) in [
              ('home', '家', homeSet),
              ('work', workName, workSet),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SizedBox(
                  height: 60,
                  child: OutlinedButton.icon(
                    key: Key('place-set-$kind'),
                    onPressed: busy || !enabled ? null : () => setHere(kind),
                    icon: Icon(set ? Icons.check_circle : Icons.place),
                    label: Text(
                      set ? '$label已設定（在這裡按可重設）' : '人在$label時，按這裡',
                      style: body,
                    ),
                  ),
                ),
              ),
            const Text('第二個地點叫做：', style: TextStyle(fontSize: 18)),
            Wrap(
              spacing: 8,
              children: [
                for (final name in placeNames)
                  ChoiceChip(
                    label: Text(name, style: const TextStyle(fontSize: 18)),
                    selected: workName == name,
                    onSelected: busy ? null : (_) => rename(name),
                  ),
              ],
            ),
          ]),
          step(3, '確認偵測', detection == '偵測設定完成', [
            Text(detection, key: const Key('place-detection'), style: body),
            if (snap['lastEvent'] is String)
              Text('最近一次：${snap['lastEvent']}', style: body),
          ]),
          if (enabled) ...[
            TextButton(
              onPressed: busy ? null : () => stop(revoke: false),
              child: const Text('暫停通知', style: TextStyle(fontSize: 18)),
            ),
            TextButton(
              onPressed: busy ? null : () => stop(revoke: true),
              child: const Text('關閉並刪除地點', style: TextStyle(fontSize: 18)),
            ),
          ],
        ],
      ),
    );
  }
}
