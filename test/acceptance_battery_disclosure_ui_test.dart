// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';
import 'package:familyhelper/app/client/battery_guardian_panel.dart';
import 'package:familyhelper/app/common/firebase_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class ReviewApi extends FirebaseService {
  final consent = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final latest = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final empty = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  int privateReads = 0;
  @override
  String get uid => 'review-client';
  @override
  Stream<Map<String, dynamic>> watch(String path) {
    if (path.endsWith('/consent')) return consent.stream;
    privateReads++;
    return path.endsWith('/latest') ? latest.stream : empty.stream;
  }

  @override
  Stream<Map<String, dynamic>> batteryEvents(String hostId) {
    privateReads++;
    return empty.stream;
  }

  Future<void> close() async {
    await consent.close();
    await latest.close();
    await empty.close();
  }
}

void main() {
  testWidgets('Legacy consent does not start private battery reads', (
    tester,
  ) async {
    final api = ReviewApi();
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BatteryGuardianPanel(
            api: api,
            hostId: 'grandma',
            notificationStatus: () async => true,
          ),
        ),
      ),
    );
    api.consent.add({'enabled': true, 'status': 'enabled', 'version': 4});
    await tester.pump();
    expect(
      api.privateReads,
      0,
      reason: 'Enabled alone is not new disclosure approval',
    );
  });
  testWidgets('Invalidated disclosure immediately hides cached battery value', (
    tester,
  ) async {
    final api = ReviewApi();
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: BatteryGuardianPanel(
              api: api,
              hostId: 'grandma',
              notificationStatus: () async => true,
            ),
          ),
        ),
      ),
    );
    api.consent.add({
      'enabled': true,
      'status': 'enabled',
      'version': 4,
      'disclosureVersion': 2,
    });
    await tester.pump();
    api.latest.add({
      'batteryPercent': 15,
      'charging': false,
      'receivedAt': DateTime.now().millisecondsSinceEpoch,
    });
    await tester.pump();
    expect(find.text('15%'), findsOneWidget);
    api.consent.add({
      'enabled': true,
      'status': 'enabled',
      'version': 4,
      'disclosureVersion': 1,
    });
    await tester.pump();
    expect(
      find.text('15%'),
      findsNothing,
      reason:
          'Cached private data cannot remain visible after consent invalidation',
    );
  });
}
