// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:flutter/material.dart';

import '../common/profile_page.dart';
import '../common/about_page.dart';
import '../common/constants.dart';
import '../common/ui/fh_widgets.dart';

import '../common/firebase_service.dart';
import 'client_reminder_settings_page.dart';
import 'client_voice_profile_page.dart';
import 'client_phone_page.dart';
import 'client_weather_settings_page.dart';
import '../common/ui/fh_tokens.dart';

/// Family settings, most-used first: morning read-aloud time, reminders.
class ClientSettingsPage extends StatefulWidget {
  final FirebaseService api;
  final String hostId;
  final Future<void> Function() onUnlink;
  const ClientSettingsPage({
    super.key,
    required this.api,
    required this.hostId,
    required this.onUnlink,
  });

  @override
  State<ClientSettingsPage> createState() => _ClientSettingsPageState();
}

class _ClientSettingsPageState extends State<ClientSettingsPage> {
  Map<String, dynamic> weather = const {},
      reminders = const {},
      plan = const {};
  final subs = <StreamSubscription<Map<String, dynamic>>>[];

  @override
  void initState() {
    super.initState();
    for (final (path, set) in [
      ('weather', (Map<String, dynamic> v) => weather = v),
      ('reminders', (Map<String, dynamic> v) => reminders = v),
      ('reminderPlan', (Map<String, dynamic> v) => plan = v),
    ]) {
      try {
        subs.add(
          widget.api
              .watch('care/${widget.hostId}/settings/$path')
              .listen((v) => setState(() => set(v)), onError: (_) {}),
        );
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    for (final s in subs) {
      s.cancel();
    }
    super.dispose();
  }

  void _open(String title, Widget body) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: body,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final city = asMap(weather['city'])['name'];
    final time = weather['morningTime'];
    final count =
        ((plan.isNotEmpty ? plan['items'] : reminders['items']) as List?)
            ?.length ??
        0;
    Widget tile(
      IconData icon,
      String title,
      String subtitle,
      VoidCallback tap, {
      Key? key,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: FhSpace.sm),
      child: Card(
        child: ListTile(
          key: key,
          minVerticalPadding: 16,
          leading: Icon(icon, size: 32, color: FhColors.brand),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: tap,
        ),
      ),
    );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        tile(
          Icons.account_circle_outlined,
          '我的名字與頭貼',
          '家人和長輩看到的稱呼和照片',
          () async {
            final family = await widget.api.read(
              'core/families/${widget.hostId}',
            );
            final name =
                asMap(asMap(family['members'])[widget.api.uid])['name']
                    as String? ??
                '';
            if (!context.mounted) return;
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ProfilePage(
                  api: widget.api,
                  hostId: widget.hostId,
                  currentName: name,
                ),
              ),
            );
          },
          key: const Key('settings-profile'),
        ),
        tile(
          Icons.wb_sunny_outlined,
          '早上幾點朗讀天氣',
          time is String
              ? '每天 $time 在長輩手機朗讀${city is String ? '「$city」' : ''}天氣和每日一句'
              : '還沒設定，點這裡選城市和時間',
          () => _open(
            '早上朗讀天氣',
            ClientWeatherSettingsPage(api: widget.api, hostId: widget.hostId),
          ),
          key: const Key('settings-morning'),
        ),
        tile(
          Icons.alarm,
          '語音提醒（吃藥、喝水、自訂…）',
          count > 0 ? '已設定 $count 個，長輩手機到時會唸出來' : '還沒設定，點這裡新增',
          () => _open(
            '每日提醒',
            ClientReminderSettingsPage(api: widget.api, hostId: widget.hostId),
          ),
          key: const Key('settings-reminders'),
        ),
        tile(
          Icons.record_voice_over,
          '我的聲音（自我介紹、早安輪流）',
          '錄一句自我介紹（例如「阿嬤，我是小明」），播報時先播你的聲音',
          () => _open(
            '我的聲音',
            ClientVoiceProfilePage(api: widget.api, hostId: widget.hostId),
          ),
          key: const Key('settings-voice'),
        ),
        tile(
          Icons.phone,
          '我的電話',
          '長輩求助沒人接時，可以一鍵打給你（長輩需確認）',
          () => _open(
            '我的電話',
            ClientPhonePage(api: widget.api, hostId: widget.hostId),
          ),
          key: const Key('settings-phone'),
        ),
        const SizedBox(height: FhSpace.sm),
        const FhStatusBanner(
          tone: FhTone.info,
          announce: false,
          message: '長輩要在自己的手機開啟「提醒與朗讀」，這些設定才會在長輩手機上執行。',
        ),
        const FhSectionHeader(title: '其他'),
        tile(
          Icons.info_outline,
          '關於 FamilyHelper',
          '作者、版權與授權',
          () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const AboutPage(role: AppRole.client),
            ),
          ),
          key: const Key('settings-about'),
        ),
        tile(
          Icons.link_off,
          '解除與長輩的配對',
          '解除後需要長輩重新產生配對碼',
          () => widget.onUnlink(),
        ),
      ],
    );
  }
}
