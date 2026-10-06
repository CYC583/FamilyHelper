// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:flutter/material.dart';

import '../common/firebase_service.dart';

/// Family member's own number for grandma's "打電話給…" fallback. Grandma must
/// confirm it on her phone before it is used; changing it needs re-confirming.
class ClientPhonePage extends StatefulWidget {
  final FirebaseService api;
  final String hostId;
  const ClientPhonePage({super.key, required this.api, required this.hostId});

  @override
  State<ClientPhonePage> createState() => _ClientPhonePageState();
}

class _ClientPhonePageState extends State<ClientPhonePage> {
  final phone = TextEditingController();
  Map<String, dynamic> mine = const {};
  StreamSubscription<Map<String, dynamic>>? sub;
  bool loaded = false, saving = false;
  String? message;

  @override
  void initState() {
    super.initState();
    try {
      final me = widget.api.uid;
      sub = widget.api.watch('care/${widget.hostId}/contacts').listen((v) {
        setState(() {
          mine = asMap(v[me]);
          if (!loaded) {
            phone.text = mine['phone'] as String? ?? '';
            loaded = true;
          }
        });
      }, onError: (_) {});
    } catch (_) {}
  }

  @override
  void dispose() {
    sub?.cancel();
    phone.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() {
      saving = true;
      message = null;
    });
    try {
      await widget.api.call('setContactPhone', {
        'hostId': widget.hostId,
        'phone': phone.text.trim(),
      });
      setState(
        () => message = phone.text.trim().isEmpty ? '已刪除' : '已儲存，請長輩在自己的手機確認',
      );
    } catch (e) {
      setState(() => message = '沒有儲存：${errorMessage(e)}');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const Text(
        '長輩求助沒人接時，長輩的畫面會出現「打電話給你」，按下後會打開撥號畫面，由長輩自己按撥出。',
        style: TextStyle(fontSize: 16),
      ),
      const SizedBox(height: 12),
      TextField(
        key: const Key('phone-input'),
        controller: phone,
        keyboardType: TextInputType.phone,
        decoration: const InputDecoration(labelText: '我的電話'),
      ),
      const SizedBox(height: 8),
      FilledButton(onPressed: saving ? null : save, child: const Text('儲存')),
      const SizedBox(height: 8),
      if (mine.isNotEmpty)
        Text(
          mine['confirmed'] == true ? '長輩已確認，可以使用' : '等長輩在「家人設定 → 家人電話」確認',
          style: const TextStyle(fontSize: 16),
        ),
      if (message != null) Text(message!),
    ],
  );
}
