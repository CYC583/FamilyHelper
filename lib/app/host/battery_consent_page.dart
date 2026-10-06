// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../common/firebase_service.dart';
import '../common/native_bridge.dart';
import '../common/ui/fh_tokens.dart';
import '../common/ui/fh_format.dart';
import '../common/ui/fh_widgets.dart';

const _batteryDisclosureVersion = 2;

/// 電量分享只可由長輩在本機開啟。沒有雲端回執時，畫面不宣稱已同步。
class BatteryConsentPage extends StatefulWidget {
  final FirebaseService api;
  final Future<bool> Function()? notificationStatus;
  const BatteryConsentPage({
    super.key,
    required this.api,
    this.notificationStatus,
  });

  @override
  State<BatteryConsentPage> createState() => _BatteryConsentPageState();
}

class _BatteryConsentPageState extends State<BatteryConsentPage> {
  Map<String, dynamic> local = {};
  bool busy = false;
  bool? notificationAllowed;
  String? message;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    try {
      final result = await NativeBridge.batterySampleNow();
      final allowed =
          await (widget.notificationStatus?.call() ??
              Permission.notification.status.then(
                (status) => status.isGranted,
              ));
      if (mounted) {
        setState(() {
          local = result;
          notificationAllowed = allowed;
        });
      }
    } catch (e) {
      if (mounted) setState(() => message = errorMessage(e));
    }
  }

  Future<void> requestNotifications() => run(() async {
    final status = await Permission.notification.request();
    if (!mounted) return;
    if (status.isPermanentlyDenied) {
      await openAppSettings();
    }
    setState(() {
      notificationAllowed = status.isGranted;
      message = status.isGranted
          ? 'Android 通知已開啟；低電量時會顯示提醒。'
          : 'Android 通知仍未開啟；若已在系統設定允許，請返回後按「更新狀態」。';
    });
  });

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
      await refresh();
    } catch (e) {
      if (mounted) setState(() => message = errorMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> enable(int version) => run(() async {
    final approved = await NativeBridge.batteryPrepareConsent();
    if (!approved) {
      if (mounted) setState(() => message = '未開啟分享，只有這支手機會提醒長輩。');
      return;
    }
    final consent = await widget.api.call('setBatteryConsent', {
      'enabled': true,
      'expectedVersion': version,
      'disclosureVersion': _batteryDisclosureVersion,
    });
    final nextVersion = (consent['version'] as num?)?.toInt();
    if (nextVersion == null) {
      throw StateError('雲端未回傳同意版本，分享沒有在本機開啟');
    }
    try {
      if (consent['disclosureVersion'] != _batteryDisclosureVersion) {
        throw StateError('雲端尚未支援新版電量同意，分享沒有在本機開啟');
      }
      local = await NativeBridge.batteryShareConsent(
        widget.api.uid,
        nextVersion,
        _batteryDisclosureVersion,
      );
    } catch (_) {
      // The server must never remain sharing when local approval failed.
      try {
        await widget.api.call('setBatteryConsent', {
          'enabled': false,
          'expectedVersion': nextVersion,
        });
      } catch (_) {
        // Show an explicit warning until the server state can be read again.
      }
      rethrow;
    }
    if (mounted) setState(() => message = '已開啟電量分享；家人能看到最新同步時間。');
  });

  Future<void> stop(int version, {bool revoke = false}) => run(() async {
    local = await NativeBridge.batteryStopSharing();
    if (mounted) setState(() => message = '本機已停止分享，正在通知雲端…');
    try {
      final consent = await widget.api.call('setBatteryConsent', {
        'enabled': false,
        'expectedVersion': version,
        'revoke': revoke,
      });
      await NativeBridge.batteryConsentSynced(
        (consent['version'] as num).toInt(),
      );
      if (mounted) setState(() => message = revoke ? '分享已撤銷' : '分享已暫停');
    } catch (_) {
      if (mounted) setState(() => message = '本機已停止，雲端撤銷待同步；請連網後重試。');
    }
  });

  String formatTime(Object? millis) {
    if (millis is! num) return '尚無紀錄';
    return friendlyTime(millis);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('長輩手機電量守護')),
    body: StreamBuilder<Map<String, dynamic>>(
      stream: widget.api.watch('care/${widget.api.uid}/battery/consent'),
      builder: (context, snapshot) {
        final cloud = snapshot.data ?? {};
        final version = (cloud['version'] as num?)?.toInt() ?? 0;
        final sharing = local['shareEnabled'] == true;
        final stopPending =
            local['revokePending'] == true ||
            (!sharing && cloud['enabled'] == true);
        final percent = local['batteryPercent'];
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              percent is num ? '目前電量 ${percent.toInt()}%' : '正在讀取手機電量',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            Text(
              '本機取樣：${formatTime(local['observedAt'])}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (local['charging'] == true)
              Text('正在充電', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 16),
            Text(
              '電量低時，這支手機會先用大字通知長輩。通知聲和朗讀依手機音量、勿擾與系統通知權限而定。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (notificationAllowed == false) ...[
              Text(
                'Android 通知尚未開啟；背景提醒、聲音與自動朗讀目前不能使用。',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: FhColors.warning),
              ),
              OutlinedButton(
                onPressed: busy ? null : requestNotifications,
                child: Text(
                  '開啟 Android 通知',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            ],
            SwitchListTile(
              title: const Text('中文朗讀低電量'),
              subtitle: const Text('只在提醒時嘗試朗讀；不保證背景一定播出'),
              value: local['voiceEnabled'] != false,
              onChanged: busy
                  ? null
                  : (value) => run(() async {
                      local = await NativeBridge.batteryVoiceEnabled(value);
                    }),
            ),
            SwitchListTile(
              title: const Text('低電量提示聲'),
              value: local['toneEnabled'] != false,
              onChanged: busy
                  ? null
                  : (value) => run(() async {
                      local = await NativeBridge.batteryToneEnabled(value);
                    }),
            ),
            const Divider(height: 28),
            Text(
              sharing ? '已在本機開啟分享' : '預設不分享給家人',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text('開啟後，這支手機會分享：', style: Theme.of(context).textTheme.bodyMedium),
            Text('• 電量百分比與充電狀態', style: Theme.of(context).textTheme.bodyMedium),
            Text('• 取樣與上次同步時間', style: Theme.of(context).textTheme.bodyMedium),
            Text('• 低電量事件與解除狀態', style: Theme.of(context).textTheme.bodyMedium),
            Text(
              '• 判斷低電量持續時間所需的事件編號與取樣計時資訊',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            Text(
              '• 電量過低時通知家人；家人可確認收到',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            Text(
              '最多六位已配對家人可查看；不分享其他手機的電量。長輩可隨時暫停或撤銷。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (!sharing && !stopPending)
              FilledButton(
                onPressed: busy || snapshot.hasError || !snapshot.hasData
                    ? null
                    : () => enable(version),
                child: Text(
                  '由長輩開啟分享',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            if (stopPending)
              FilledButton(
                onPressed: busy || snapshot.hasError || !snapshot.hasData
                    ? null
                    : () => stop(version),
                child: Text(
                  '重試停止雲端分享',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            if (sharing) ...[
              OutlinedButton(
                onPressed: busy || !snapshot.hasData
                    ? null
                    : () => stop(version),
                child: Text(
                  '暫停分享',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              TextButton(
                onPressed: busy || !snapshot.hasData
                    ? null
                    : () => stop(version, revoke: true),
                child: Text(
                  '撤銷分享',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            ],
            if (stopPending)
              Text(
                '本機已停止，雲端撤銷待同步',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: FhColors.warning),
              ),
            if (snapshot.hasError)
              FhStatusBanner(
                tone: FhTone.danger,
                message: '雲端狀態讀取失敗：${errorMessage(snapshot.error!)}',
              ),
            Text('上次成功同步：${formatTime(local['lastSyncedAt'])}'),
            if (local['syncError'] != null)
              Text('同步遇到問題：${local['syncError']}'),
            if (local['lastVoiceError'] != null)
              Text('朗讀狀態：${local['lastVoiceError']}'),
            if (local['lastNotificationError'] != null)
              Text('通知狀態：${local['lastNotificationError']}'),
            OutlinedButton(
              onPressed: busy ? null : refresh,
              child: const Text('更新狀態'),
            ),
            if (message != null) FhStatusBanner(message: message!),
          ],
        );
      },
    ),
  );
}
