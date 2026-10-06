// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:familyhelper/app/client/remote_view_page.dart';
import 'package:familyhelper/app/common/firebase_service.dart';
import 'package:familyhelper/app/common/native_bridge.dart';
import 'package:familyhelper/app/common/rtc_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

void main() {
  testWidgets('ending a session removes the last shared frame', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, (call) async => null);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeBridge.channel, null),
    );
    final session = RtcSession(
      api: FirebaseService(),
      id: 'ended-session',
      isHost: false,
    );
    await session.close(notifyServer: false);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: RemoteScreen(session: session)),
      ),
    );

    expect(find.byType(RTCVideoView), findsNothing);
    expect(find.text('畫面分享已結束'), findsOneWidget);
  });
}
