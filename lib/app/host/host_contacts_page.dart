// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:flutter/material.dart';

import '../common/firebase_service.dart';
import '../common/ui/fh_tokens.dart';

/// Grandma confirms each family phone number before it appears as a
/// "打電話給…" button on her help screen.
class HostContactsPage extends StatefulWidget {
  final FirebaseService api;
  const HostContactsPage({super.key, required this.api});

  @override
  State<HostContactsPage> createState() => _HostContactsPageState();
}

class _HostContactsPageState extends State<HostContactsPage> {
  Map<String, dynamic> contacts = const {};
  StreamSubscription<Map<String, dynamic>>? sub;
  String? message;

  @override
  void initState() {
    super.initState();
    try {
      sub = widget.api
          .watch('care/${widget.api.uid}/contacts')
          .listen(
            (v) => setState(() => contacts = v),
            onError: (Object e) {
              setState(() => message = errorMessage(e));
            },
          );
    } catch (e) {
      message = errorMessage(e);
    }
  }

  @override
  void dispose() {
    sub?.cancel();
    super.dispose();
  }

  Future<void> confirm(String uid, bool ok) async {
    try {
      await widget.api.call('confirmContactPhone', {
        'uid': uid,
        'confirmed': ok,
      });
      setState(() => message = ok ? '已確認' : '已取消');
    } catch (e) {
      setState(() => message = '沒有儲存：${errorMessage(e)}');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('家人電話')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          '家人在自己的手機填好電話後，會出現在這裡。確認是對的，按「是，這是他的電話」。求助沒人接時，畫面會出現「打電話給…」。',
          style: TextStyle(fontSize: 20),
        ),
        if (message != null)
          Text(
            message!,
            style: const TextStyle(fontSize: 18, color: FhColors.brand),
          ),
        if (contacts.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 20),
            child: Text('家人還沒有填電話', style: TextStyle(fontSize: 20)),
          ),
        for (final e in contacts.entries)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${asMap(e.value)['name'] ?? '家人'}：${asMap(e.value)['phone']}',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  asMap(e.value)['confirmed'] == true
                      ? Row(
                          children: [
                            const Icon(
                              Icons.check_circle,
                              color: FhColors.brand,
                            ),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                '已確認',
                                style: TextStyle(fontSize: 20),
                              ),
                            ),
                            TextButton(
                              onPressed: () => confirm(e.key, false),
                              child: const Text(
                                '取消確認',
                                style: TextStyle(fontSize: 18),
                              ),
                            ),
                          ],
                        )
                      : SizedBox(
                          width: double.infinity,
                          height: 64,
                          child: FilledButton(
                            key: Key('contact-confirm-${e.key}'),
                            onPressed: () => confirm(e.key, true),
                            child: const Text(
                              '是，這是他的電話',
                              style: TextStyle(fontSize: 22),
                            ),
                          ),
                        ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
