// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:flutter/material.dart';

import '../common/family_messages_panel.dart';
import '../common/firebase_service.dart';
import '../common/native_bridge.dart';

/// Grandma's "家人" tab: the family chat with one big hold-to-talk button.
/// New messages are read aloud by the phone (native side de-duplicates).
class HostFamilyPage extends StatefulWidget {
  final FirebaseService api;
  final VoicePort voice;
  const HostFamilyPage({
    super.key,
    required this.api,
    this.voice = const NativeVoicePort(),
  });

  @override
  State<HostFamilyPage> createState() => _HostFamilyPageState();
}

class _HostFamilyPageState extends State<HostFamilyPage> {
  Map<String, String> names = const {};
  StreamSubscription<Map<String, dynamic>>? sub;

  @override
  void initState() {
    super.initState();
    try {
      sub = widget.api.family(widget.api.uid).listen((family) {
        setState(
          () => names = {
            for (final e in asMap(family['members']).entries)
              e.key: (asMap(e.value)['name'] as String?) ?? '家人',
          },
        );
      }, onError: (_) {});
    } catch (_) {}
  }

  @override
  void dispose() {
    sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: FamilyMessagesPanel(
            api: widget.api,
            hostId: widget.api.uid,
            selfUid: widget.api.uid,
            isHost: true,
            names: names,
            voice: widget.voice,
            fillHeight: true,
            onIncoming: (who, message) =>
                unawaited(NativeBridge.careRunNow().catchError((_) {})),
          ),
        ),
      ),
    ),
  );
}
