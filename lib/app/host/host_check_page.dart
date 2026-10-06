// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../common/firebase_service.dart';
import '../common/native_bridge.dart';
import 'battery_consent_page.dart';
import 'host_care_settings_page.dart';
import 'host_place_alerts_page.dart';
import 'host_sharing_page.dart';
import '../common/ui/fh_tokens.dart';

/// One line of the check: what it is, whether it looks fine, and how to fix.
class CheckRow {
  final String title, detail;
  final bool? ok; // null = could not check
  final String? action;
  final Future<void> Function()? onFix;
  const CheckRow(this.title, this.detail, this.ok, {this.action, this.onFix});
}

/// Grandma's own "is my phone set up right" page plus a plain list of what is
/// shared with family right now. It only reads local settings; it never says a
/// reminder or alert is guaranteed to arrive.
class HostCheckPage extends StatefulWidget {
  final FirebaseService api;
  const HostCheckPage({super.key, required this.api});
  @override
  State<HostCheckPage> createState() => _HostCheckPageState();
}

class _HostCheckPageState extends State<HostCheckPage>
    with WidgetsBindingObserver {
  Map<String, dynamic> care = const {},
      place = const {},
      battery = const {},
      app = const {},
      location = const {},
      usage = const {};
  bool? accessibility;
  bool health = false;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Coming back from Android settings re-checks automatically.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) load();
  }

  Future<T> _try<T>(Future<T> Function() f, T fallback) async {
    try {
      return await f();
    } catch (_) {
      return fallback;
    }
  }

  Future<void> load() async {
    final results = await Future.wait<Object?>([
      _try(NativeBridge.careSnapshot, const <String, dynamic>{}),
      _try(NativeBridge.placeSnapshot, const <String, dynamic>{}),
      _try(NativeBridge.batterySnapshot, const <String, dynamic>{}),
      _try(NativeBridge.appInfo, const <String, dynamic>{}),
      _try<bool?>(NativeBridge.accessibilityEnabled, null),
      _try(NativeBridge.locationSnapshot, const <String, dynamic>{}),
      _try(NativeBridge.usageSnapshot, const <String, dynamic>{}),
      _try<bool>(
        () async =>
            (await SharedPreferences.getInstance()).getBool('healthEnabled') ??
            false,
        false,
      ),
    ]);
    if (!mounted) return;
    setState(() {
      care = results[0] as Map<String, dynamic>;
      place = results[1] as Map<String, dynamic>;
      battery = results[2] as Map<String, dynamic>;
      app = results[3] as Map<String, dynamic>;
      accessibility = results[4] as bool?;
      location = results[5] as Map<String, dynamic>;
      usage = results[6] as Map<String, dynamic>;
      health = results[7] as bool;
      loading = false;
    });
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => page));
    await load();
  }

  List<CheckRow> get checks {
    final sound = asMap(care['sound']);
    final problems = [
      for (final p in (sound['problems'] as List? ?? const [])) '$p',
    ];
    final remindersOn = care['enabled'] == true;
    final placeOn = place['enabled'] == true;
    return [
      CheckRow(
        '通知',
        care['notificationsAllowed'] == true
            ? '已允許，提醒會跳出來'
            : care.isEmpty
            ? '無法檢查'
            : '沒有允許，提醒和求助回覆可能看不到',
        care.isEmpty ? null : care['notificationsAllowed'] == true,
        action: '去開啟',
        onFix: NativeBridge.openNotificationSettings,
      ),
      CheckRow(
        '提醒朗讀',
        !remindersOn
            ? '還沒開啟，家人設的提醒不會唸'
            : (care['disclosure'] as num? ?? 0) < 2
            ? '需要重新看一次說明再同意'
            : '已開啟',
        care.isEmpty
            ? null
            : remindersOn && (care['disclosure'] as num? ?? 0) >= 2,
        action: '去設定',
        onFix: () => _open(HostCareSettingsPage(api: widget.api)),
      ),
      CheckRow(
        '聲音',
        problems.isEmpty ? '鈴聲和媒體音量正常' : problems.join('；'),
        sound.isEmpty ? null : problems.isEmpty,
        action: '調整聲音',
        onFix: NativeBridge.openSoundSettings,
      ),
      CheckRow(
        '讓家人幫忙點手機',
        accessibility == true ? '已開啟（每次仍要你同意）' : '沒有開啟，家人只能看不能點',
        accessibility,
        action: '去開啟',
        onFix: NativeBridge.accessibilitySettings,
      ),
      CheckRow(
        '背景執行',
        app['batteryUnrestricted'] == true ? '已設為不限制' : '可能被省電關掉，請設為「無限制」',
        app['batteryUnrestricted'] as bool?,
        action: '去設定',
        onFix: NativeBridge.batterySettings,
      ),
      if (placeOn)
        CheckRow(
          '出門到家偵測',
          place['backgroundPermission'] != true
              ? '位置權限要選「一律允許」才會偵測'
              : place['registered'] == true
              ? '偵測中'
              : '還沒開始偵測，請打開設定確認',
          place['backgroundPermission'] == true && place['registered'] == true,
          action: '去設定',
          onFix: () => _open(HostPlaceAlertsPage(api: widget.api)),
        ),
    ];
  }

  List<CheckRow> get sharing {
    final items = asMap(care['companionItems']);
    final shared = [
      if (items['responses'] == true) '提醒的回覆',
      if (items['mood'] == true) '今天的心情',
      if (items['sound'] == true) '手機是不是靜音',
    ];
    return [
      CheckRow(
        '電量',
        battery['shareEnabled'] == true ? '正在分享電量給家人' : '沒有分享',
        battery['shareEnabled'] == true,
        action: '查看或暫停',
        onFix: () => _open(BatteryConsentPage(api: widget.api)),
      ),
      CheckRow(
        '出門、到家',
        place['enabled'] == true ? '會通知家人「出門了／到家了」，不傳位置' : '沒有分享',
        place['enabled'] == true,
        action: '查看或暫停',
        onFix: () => _open(HostPlaceAlertsPage(api: widget.api)),
      ),
      CheckRow(
        '提醒有沒有播出',
        care['enabled'] == true ? '家人看得到提醒播了沒有' : '沒有分享',
        care['enabled'] == true,
        action: '查看或暫停',
        onFix: () => _open(HostCareSettingsPage(api: widget.api)),
      ),
      CheckRow(
        '心情與回覆',
        shared.isEmpty ? '沒有分享' : '正在分享：${shared.join('、')}',
        shared.isNotEmpty,
        action: '查看或暫停',
        onFix: () => _open(HostCareSettingsPage(api: widget.api)),
      ),
      CheckRow(
        '我的位置',
        location['enabled'] == true ? '家人看得到手機在地圖上的位置，也能讓手機響' : '沒有分享',
        location['enabled'] == true,
        action: '查看或關閉',
        onFix: () => _open(HostSharingPage(api: widget.api, kind: 'location')),
      ),
      CheckRow(
        '手機使用時間',
        usage['enabled'] == true ? '家人看得到每個 App 用了多久' : '沒有分享',
        usage['enabled'] == true,
        action: '查看或關閉',
        onFix: () => _open(HostSharingPage(api: widget.api, kind: 'usage')),
      ),
      CheckRow('健康資料', health ? '打開 App 時會分享心跳等健康資料' : '沒有分享', health),
      const CheckRow('照片', '你拍的照片和說的話，家人看得到', true),
      const CheckRow('手機畫面', '只有你按「同意」那一次會分享，可以隨時停止', true),
    ];
  }

  Widget _row(CheckRow r, {required bool sharingList}) {
    final color = r.ok == null
        ? FhColors.inkMuted
        : r.ok!
        ? FhColors.brand
        : sharingList
        ? FhColors.inkMuted
        : FhColors.danger;
    final icon = r.ok == null
        ? Icons.help_outline
        : sharingList
        ? (r.ok! ? Icons.visibility : Icons.visibility_off)
        : (r.ok! ? Icons.check_circle : Icons.error);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 32),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    r.title,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(r.detail, style: TextStyle(fontSize: 20, color: color)),
            if (r.onFix != null && (sharingList || r.ok != true))
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(140, 56),
                    ),
                    onPressed: r.onFix,
                    child: Text(
                      r.action!,
                      style: const TextStyle(fontSize: 20),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = checks;
    final bad = list.where((c) => c.ok == false).length;
    return Scaffold(
      appBar: AppBar(title: const Text('手機檢查')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    bad == 0 ? '看起來都設定好了' : '有 $bad 項要調整',
                    key: const Key('check-summary'),
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Text(
                    '這裡只檢查手機的設定，不能保證每次提醒或通知一定送到。',
                    style: TextStyle(fontSize: 18),
                  ),
                  const SizedBox(height: 8),
                  for (final c in list) _row(c, sharingList: false),
                  const SizedBox(height: 20),
                  const Text(
                    '我正在分享什麼',
                    key: Key('sharing-title'),
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                  ),
                  const Text(
                    '畫面只在你同意的那次分享；其他項目都可以在這裡關閉。',
                    style: TextStyle(fontSize: 18),
                  ),
                  const SizedBox(height: 8),
                  for (final c in sharing) _row(c, sharingList: true),
                  if (app['version'] is String)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        'App 版本：${app['version']}',
                        style: const TextStyle(fontSize: 18),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
