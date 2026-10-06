// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:familyhelper/app/common/fcm_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('電量通知 ID 與同一事件固定，與瞬時 FCM messageId 無關', () {
    expect(
      batteryNotificationId('host-a', 'episode-1'),
      batteryNotificationId('host-a', 'episode-1'),
    );
    expect(
      batteryNotificationId('host-a', 'episode-1'),
      isNot(batteryNotificationId('host-a', 'episode-2')),
    );
  });
}
