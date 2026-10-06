// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../common/firebase_service.dart';
import '../common/native_bridge.dart';
import '../common/ui/fh_widgets.dart';

/// Host-only: local reminders/speech, the rest reminder, a sound check and
/// itemised companion sharing. Family can never switch any of these on.
class HostCareSettingsPage extends StatefulWidget {
  final FirebaseService api;
  const HostCareSettingsPage({super.key, required this.api});

  @override
  State<HostCareSettingsPage> createState() => _HostCareSettingsPageState();
}

class _HostCareSettingsPageState extends State<HostCareSettingsPage>
    with WidgetsBindingObserver {
  static const disclosureVersion = 1;
  Map<String, dynamic> snap = const {};
  Map<String, dynamic> cloudConsent = const {};
  StreamSubscription<Map<String, dynamic>>? consentSub;
  final pick = {'responses': true, 'mood': true, 'sound': false};
  bool busy = false;
  String? message;
  int loud = 2;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refresh();
    try {
      consentSub = widget.api
          .watch('care/${widget.api.uid}/companion/consent')
          .listen(
            (value) => setState(() => cloudConsent = value),
            onError: (Object e) =>
                setState(() => message = '分享狀態無法讀取：${errorMessage(e)}'),
          );
    } catch (e) {
      message = '分享狀態無法讀取：${errorMessage(e)}';
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    consentSub?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    try {
      final level = await NativeBridge.loudLevel();
      if (mounted) setState(() => loud = level);
    } catch (_) {}
    try {
      final value = await NativeBridge.careSnapshot();
      if (mounted) setState(() => snap = value);
    } catch (e) {
      if (mounted) setState(() => message = '手機狀態無法讀取：${errorMessage(e)}');
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
      if (mounted) setState(() => message = errorMessage(e));
    } finally {
      await refresh();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> enableReminders() => guard(() async {
    if (!await NativeBridge.reminderPrepareConsent()) {
      setState(() => message = '沒有開啟；你可以之後再開');
      return;
    }
    await Permission.notification.request();
    await NativeBridge.reminderEnable(widget.api.uid);
    setState(() => message = '已開啟。提醒在這支手機執行，可能晚幾分鐘。');
  });

  Future<void> disableReminders() => guard(() async {
    await NativeBridge.reminderDisable();
    setState(() => message = '已關閉提醒與朗讀');
  });

  Future<void> share() => guard(() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final text = Theme.of(ctx).textTheme;
        return AlertDialog(
          title: Text('分享給家人', style: text.titleLarge),
          content: SingleChildScrollView(
            child: Text(
              '同意後，已配對的家人可以看到：\n'
              '${pick['responses']! ? '・你對提醒按了「吃了／稍後／略過」與時間（不含藥名）\n' : ''}'
              '${pick['mood']! ? '・你選的今天心情\n' : ''}'
              '${pick['sound']! ? '・手機是否靜音、勿擾或媒體音量為零；靜音超過一小時會通知家人\n' : ''}'
              '\n不會分享 App 名稱、畫面、通話或位置。你可以隨時暫停或撤銷；撤銷會刪除已分享的紀錄。',
              style: text.bodyLarge,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('先不要', style: text.labelLarge),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('同意分享', style: text.labelLarge),
            ),
          ],
        );
      },
    );
    if (ok != true) return;
    final consent = await widget.api.call('setCompanionConsent', {
      'action': 'enable',
      'items': pick,
      'disclosureVersion': disclosureVersion,
    });
    final version = (consent['version'] as num?)?.toInt() ?? 0;
    await NativeBridge.careSetCompanion(
      widget.api.uid,
      version,
      Map<String, bool>.from(
        asMap(consent['items']).map((k, v) => MapEntry(k, v == true)),
      ),
    );
    setState(() => message = '已開始分享你勾選的項目');
  });

  Future<void> stopSharing(String action) => guard(() async {
    // Stop locally first so nothing more is uploaded even if offline.
    await NativeBridge.careStopCompanion();
    await widget.api.call('setCompanionConsent', {'action': action});
    setState(() => message = action == 'pause' ? '已暫停分享' : '已撤銷分享並刪除已分享紀錄');
  });

  @override
  Widget build(BuildContext context) {
    final enabled =
        snap['enabled'] == true && (snap['disclosure'] as num? ?? 1) >= 2;
    final sound = asMap(snap['sound']);
    final problems = (sound['problems'] as List?)?.cast<String>() ?? const [];
    final sharing =
        cloudConsent['enabled'] == true && cloudConsent['status'] == 'enabled';
    final items = asMap(cloudConsent['items']);
    final text = Theme.of(context).textTheme;
    final title = text.titleLarge;
    final body = text.bodyLarge;
    return Scaffold(
      appBar: AppBar(title: const Text('提醒、朗讀與分享')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (message != null) FhStatusBanner(message: message!),
          Text('家人設定的提醒', style: title),
          Text(
            enabled ? '已開啟。到時間會顯示通知，有聲音時會朗讀。' : '尚未開啟。開啟前，家人設定的提醒不會在這支手機跳出。',
            style: body,
          ),
          if (snap['notificationsAllowed'] == false)
            TextButton(
              onPressed: NativeBridge.openNotificationSettings,
              child: const Text('通知權限未開啟，點這裡到系統設定'),
            ),
          const SizedBox(height: 8),
          SizedBox(
            height: 64,
            child: enabled
                ? OutlinedButton(
                    onPressed: busy ? null : disableReminders,
                    child: Text('關閉提醒與朗讀', style: body),
                  )
                : FilledButton(
                    onPressed: busy ? null : enableReminders,
                    child: Text('開啟提醒與朗讀', style: body),
                  ),
          ),
          const Divider(height: 32),
          Text('播報音量加強', style: title),
          Text('手機開到最大聲還是太小時，選「強」可以再放大（聲音可能有一點破）。', style: text.bodyMedium),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            key: const Key('loud-level'),
            segments: [
              ButtonSegment(value: 0, label: Text('關', style: text.labelLarge)),
              ButtonSegment(value: 1, label: Text('中', style: text.labelLarge)),
              ButtonSegment(value: 2, label: Text('強', style: text.labelLarge)),
            ],
            selected: {loud},
            onSelectionChanged: (v) async {
              setState(() => loud = v.first);
              try {
                await NativeBridge.setLoudLevel(v.first);
                await NativeBridge.speakText('長輩，這是現在的播報音量。');
              } catch (_) {}
            },
          ),
          TextButton.icon(
            onPressed: () =>
                NativeBridge.speakText('長輩，這是現在的播報音量。').catchError((_) {}),
            icon: const Icon(Icons.volume_up),
            label: Text('試聽', style: text.labelLarge),
          ),
          const Divider(height: 32),
          SwitchListTile(
            value: snap['restEnabled'] == true,
            onChanged: busy
                ? null
                : (value) => guard(() => NativeBridge.careSetRest(value)),
            title: Text('看手機太久提醒休息', style: title),
            subtitle: Text(
              '螢幕連續亮約 90 分鐘時提醒。只看螢幕亮暗，不看你在用哪個 App。週一到週五 9:00–13:30 股市開盤時會等收盤再提醒。',
              style: text.bodyMedium,
            ),
          ),
          const Divider(height: 32),
          Text('檢查聲音', style: title),
          if (sound.isEmpty)
            const FhEmptyState(
              icon: Icons.volume_off_outlined,
              title: '無法判定聲音狀態',
            )
          else if (problems.isEmpty)
            Text('鈴聲與媒體音量看起來正常', style: body)
          else
            for (final p in problems) Text('・$p', style: body),
          TextButton(
            onPressed: NativeBridge.openSoundSettings,
            child: Text('打開聲音設定（請自己調整）', style: text.labelLarge),
          ),
          TextButton(onPressed: refresh, child: const Text('重新檢查')),
          const Divider(height: 32),
          Text('分享給家人（可選）', style: title),
          Text(
            sharing
                ? '分享中：${[if (items['responses'] == true) '提醒回覆', if (items['mood'] == true) '心情', if (items['sound'] == true) '聲音狀態'].join('、')}'
                : cloudConsent['status'] == 'paused'
                ? '已暫停分享'
                : cloudConsent['status'] == 'revoked'
                ? '已撤銷分享'
                : '目前沒有分享',
            style: body,
          ),
          if (!sharing) ...[
            for (final (key, label) in [
              ('responses', '提醒回覆（不含藥名）'),
              ('mood', '今天心情'),
              ('sound', '手機是否靜音'),
            ])
              CheckboxListTile(
                value: pick[key],
                onChanged: busy
                    ? null
                    : (value) => setState(() => pick[key] = value == true),
                title: Text(label, style: body),
              ),
            SizedBox(
              height: 64,
              child: FilledButton(
                onPressed: busy || !pick.values.any((v) => v) ? null : share,
                child: Text('看說明並同意分享', style: body),
              ),
            ),
          ] else ...[
            SizedBox(
              height: 64,
              child: OutlinedButton(
                onPressed: busy ? null : () => stopSharing('pause'),
                child: Text('暫停分享', style: body),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: busy ? null : () => stopSharing('revoke'),
              child: Text('撤銷並刪除已分享紀錄', style: text.labelLarge),
            ),
          ],
        ],
      ),
    );
  }
}
