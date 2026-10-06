// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'firebase_service.dart';

/// Stable across app restarts and Dart isolates. Android notification IDs are
/// signed 32-bit values; the event identity, not the FCM delivery, is key.
int batteryNotificationId(String hostId, String eventId) {
  var hash = 0x811c9dc5;
  for (final byte in '$hostId:$eventId'.codeUnits) {
    hash = ((hash ^ byte) * 0x01000193) & 0x7fffffff;
  }
  return hash;
}

/// Background notifications are rendered by FCM itself. Notification taps open
/// the app; the app always reads authoritative pending sessions from RTDB.
/// Never accept a session or turn on the camera from notification payloads.
class FcmService {
  final FirebaseService api;
  final notifications = FlutterLocalNotificationsPlugin();
  StreamSubscription<String>? _token;
  StreamSubscription<RemoteMessage>? _messages;
  FcmService(this.api);

  Future<void> start() async {
    await notifications.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_family'),
      ),
    );
    await notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            'family_alerts',
            '家人求助通知',
            description: '求助、SOS 與連線請求',
            importance: Importance.max,
          ),
        );
    final android = notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        'care_battery_sound',
        '長輩電量提醒（有聲）',
        description: '長輩手機持續低電量；聲音仍受手機設定限制',
        importance: Importance.high,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        'care_battery_silent',
        '長輩電量提醒（靜音）',
        description: '長輩手機持續低電量；只顯示訊息',
        importance: Importance.defaultImportance,
        playSound: false,
        enableVibration: false,
      ),
    );
    await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) await api.call('savePushToken', {'token': token});
    _token = FirebaseMessaging.instance.onTokenRefresh.listen((token) async {
      try {
        await api.call('savePushToken', {'token': token});
      } catch (_) {
        /* retried next app launch */
      }
    });
    _messages = FirebaseMessaging.onMessage.listen((message) async {
      final note = message.notification;
      if (note == null) return;
      final battery = message.data['type'] == 'careBattery';
      final hostId = message.data['hostId'];
      final eventId = message.data['eventId'];
      if (battery && (hostId == null || eventId == null)) return;
      final channel = message.notification?.android?.channelId;
      final silent = battery && channel == 'care_battery_silent';
      await notifications.show(
        battery
            ? batteryNotificationId(hostId!, eventId!)
            : (message.messageId ?? '').hashCode & 0x7fffffff,
        note.title,
        note.body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            battery
                ? (silent ? 'care_battery_silent' : 'care_battery_sound')
                : 'family_alerts',
            battery ? (silent ? '長輩電量提醒（靜音）' : '長輩電量提醒（有聲）') : '家人求助通知',
            importance: silent ? Importance.defaultImportance : Importance.max,
            priority: silent ? Priority.defaultPriority : Priority.high,
            playSound: !silent,
            icon: 'ic_stat_family',
          ),
        ),
      );
    });
  }

  Future<void> dispose() async {
    await _token?.cancel();
    await _messages?.cancel();
  }
}
