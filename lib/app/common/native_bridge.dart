// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';
import 'package:flutter/services.dart';
import 'firebase_service.dart';

class NativeBridge {
  static const channel = MethodChannel('familyhelper/native');
  static final events = StreamController<String>.broadcast();
  static void initialize() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'stopSession') events.add('stop');
      if (call.method == 'widgetReady') events.add('widget');
      if (call.method == 'batteryChanged') events.add('battery');
      if (call.method == 'voicePlaybackDone') events.add('voiceDone');
    });
  }

  static Future<bool> consent(String id, String name) async =>
      await channel.invokeMethod<bool>('requestConsent', {
        'sessionId': id,
        'name': name,
      }) ??
      false;
  static Future<void> cancelConsent(String id) =>
      channel.invokeMethod('cancelConsent', {'sessionId': id});
  static Future<void> startCapture(String id) =>
      channel.invokeMethod('startCaptureService', {'sessionId': id});
  static Future<void> startCall() => channel.invokeMethod('startCallService');
  static Future<void> stop() => channel.invokeMethod('stopServices');
  static Future<bool> keepAlive(String id) async =>
      await channel.invokeMethod<bool>('keepAlive', {'sessionId': id}) ?? false;
  static Future<Map<String, dynamic>> geometry() async =>
      asMap(await channel.invokeMethod('geometry'));
  static Future<bool> gesture(Map<String, dynamic> data) async =>
      await channel.invokeMethod<bool>('gesture', data) ?? false;
  static Future<bool> accessibilityEnabled() async =>
      await channel.invokeMethod<bool>('accessibilityEnabled') ?? false;
  static Future<void> accessibilitySettings() =>
      channel.invokeMethod('accessibilitySettings');
  static Future<void> batterySettings() =>
      channel.invokeMethod('batterySettings');
  static Future<Map<String, dynamic>> batterySnapshot() async =>
      asMap(await channel.invokeMethod('batterySnapshot'));
  static Future<Duration> screenOnDuration() async {
    final millis = await channel.invokeMethod<num>('screenOnDuration') ?? 0;
    return Duration(milliseconds: millis.toInt().clamp(0, 24 * 60 * 60 * 1000));
  }

  static Future<Map<String, dynamic>> batterySampleNow() async =>
      asMap(await channel.invokeMethod('batterySampleNow'));
  static Future<bool> batteryPrepareConsent() async =>
      await channel.invokeMethod<bool>('batteryPrepareConsent') ?? false;
  static Future<Map<String, dynamic>> batteryShareConsent(
    String hostUid,
    int version,
    int disclosureVersion,
  ) async => asMap(
    await channel.invokeMethod('batteryShareConsent', {
      'hostUid': hostUid,
      'version': version,
      'disclosureVersion': disclosureVersion,
    }),
  );
  static Future<Map<String, dynamic>> batteryStopSharing() async =>
      asMap(await channel.invokeMethod('batteryStopSharing'));
  static Future<void> batteryConsentSynced(int version) =>
      channel.invokeMethod('batteryConsentSynced', {'version': version});
  static Future<Map<String, dynamic>> batteryVoiceEnabled(bool enabled) async =>
      asMap(
        await channel.invokeMethod('batteryVoiceEnabled', {'enabled': enabled}),
      );
  static Future<Map<String, dynamic>> batteryToneEnabled(bool enabled) async =>
      asMap(
        await channel.invokeMethod('batteryToneEnabled', {'enabled': enabled}),
      );
  static Future<Map<String, dynamic>> batteryAcknowledgeLocal() async =>
      asMap(await channel.invokeMethod('batteryAcknowledgeLocal'));
  static Future<Map<String, dynamic>> batteryRetrySync() async =>
      asMap(await channel.invokeMethod('batteryRetrySync'));
  static Future<bool> batteryConfigureEmulator({
    String host = '10.0.2.2',
    int authPort = 9099,
    int functionsPort = 5001,
  }) async =>
      await channel.invokeMethod<bool>('batteryConfigureEmulator', {
        'host': host,
        'authPort': authPort,
        'functionsPort': functionsPort,
      }) ??
      false;
  static Future<String?> widgetAction() =>
      channel.invokeMethod<String>('consumeWidgetAction');
  static Future<void> showLargeMessage(String value) =>
      channel.invokeMethod('showLargeMessage', {'text': value});
  static Future<bool> previewSpeak(String text) async =>
      await channel.invokeMethod<bool>('previewSpeak', {'text': text}) ?? false;
  static Future<bool> savePhotoToAlbum(Uint8List jpeg) async =>
      await channel.invokeMethod<bool>('savePhotoToAlbum', {'jpeg': jpeg}) ??
      false;

  // ---- Host companion (local reminders, morning card, rest, sound) ----
  static Future<Map<String, dynamic>> careSnapshot() async =>
      asMap(await channel.invokeMethod('careSnapshot'));
  static Future<bool> reminderPrepareConsent() async =>
      await channel.invokeMethod<bool>('reminderPrepareConsent') ?? false;
  static Future<void> reminderEnable(String hostUid) =>
      channel.invokeMethod('reminderEnable', {'hostUid': hostUid});
  static Future<void> reminderDisable() =>
      channel.invokeMethod('reminderDisable');
  static Future<void> careSaveConfig(String databaseUrl, String hostUid) =>
      channel.invokeMethod('careSaveConfig', {
        'databaseUrl': databaseUrl,
        'hostUid': hostUid,
      });
  static Future<bool> careSaveReminderPlan(
    String hostUid,
    Map<String, dynamic> plan,
  ) async =>
      await channel.invokeMethod<bool>('careSaveReminderPlan', {
        'hostUid': hostUid,
        'plan': {
          'version': plan['version'],
          'timezone': plan['timezone'],
          'items': [
            for (final item in (plan['items'] as List? ?? const []))
              if (item is Map)
                {
                  for (final key in const [
                    'id',
                    'type',
                    'time',
                    'repeat',
                    'date',
                    'voiceId',
                    'author',
                    'createdBy',
                    'days',
                    'pausedUntil',
                  ])
                    if (item[key] != null) key: item[key],
                  'text': item['text'] ?? '',
                },
          ],
        },
      }) ??
      false;
  static Future<void> careSaveQuotes(Map<String, String> quotes) =>
      channel.invokeMethod('careSaveQuotes', {'quotes': quotes});
  static Future<void> careSaveWeather(Map<String, dynamic>? weather) {
    final city = asMap(weather?['city']);
    return channel.invokeMethod('careSaveWeather', {
      if (city['name'] is String) ...{
        'city': city['name'],
        'latitude': (city['latitude'] as num?)?.toDouble(),
        'longitude': (city['longitude'] as num?)?.toDouble(),
        'morningTime': weather?['morningTime'],
        'version': (weather?['version'] as num?)?.toInt() ?? 0,
      },
    });
  }

  static Future<void> careRespond({
    required String date,
    required String key,
    required String type,
    required String time,
    required String text,
    required String response,
  }) => channel.invokeMethod('careRespond', {
    'date': date,
    'key': key,
    'type': type,
    'time': time,
    'text': text,
    'response': response,
  });
  static Future<void> careSetRest(bool enabled) =>
      channel.invokeMethod('careSetRest', {'enabled': enabled});
  static Future<void> careSetCompanion(
    String hostUid,
    int version,
    Map<String, bool> items,
  ) => channel.invokeMethod('careSetCompanion', {
    'hostUid': hostUid,
    'version': version,
    'items': items,
  });
  static Future<void> careStopCompanion() =>
      channel.invokeMethod('careStopCompanion');
  static Future<void> careRunNow() => channel.invokeMethod('careRunNow');
  static Future<void> openSoundSettings() =>
      channel.invokeMethod('openSoundSettings');
  static Future<void> openNotificationSettings() =>
      channel.invokeMethod('openNotificationSettings');

  // ---- Voice notes (both apps) ----
  static Future<void> voiceStart() => channel.invokeMethod('voiceStart');
  static Future<Map<String, dynamic>> voiceStop() async =>
      asMap(await channel.invokeMethod('voiceStop'));
  static Future<void> voiceCancel() => channel.invokeMethod('voiceCancel');
  static Future<void> voicePlay(String audioBase64) =>
      channel.invokeMethod('voicePlay', {'audioBase64': audioBase64});
  static Future<void> voiceStopPlay() => channel.invokeMethod('voiceStopPlay');

  static Future<Map<String, dynamic>> voiceLevel() async =>
      asMap(await channel.invokeMethod('voiceLevel'));
  static Future<void> speakText(String text) =>
      channel.invokeMethod('speakText', {'text': text});
  static Future<bool> hostCallConsent(String sessionId) async =>
      await channel.invokeMethod<bool>('hostCallConsent', {
        'sessionId': sessionId,
      }) ??
      false;
  static Future<bool> activateCall(String sessionId) async =>
      await channel.invokeMethod<bool>('activateCall', {
        'sessionId': sessionId,
      }) ??
      false;

  static Future<void> careSaveVoiceProfiles(Map<String, dynamic> profiles) =>
      channel.invokeMethod('careSaveVoiceProfiles', {'profiles': profiles});

  // ---- Leave/arrive alerts (host) ----
  static Future<Map<String, dynamic>> placeSnapshot() async =>
      asMap(await channel.invokeMethod('placeSnapshot'));
  static Future<bool> placePrepareConsent() async =>
      await channel.invokeMethod<bool>('placePrepareConsent') ?? false;
  static Future<bool> placeSetHere(String kind) async =>
      await channel.invokeMethod<bool>('placeSetHere', {'kind': kind}) ?? false;
  static Future<void> placeEnable(String hostUid, int version) => channel
      .invokeMethod('placeEnable', {'hostUid': hostUid, 'version': version});
  static Future<void> placeDisable({bool forget = false}) =>
      channel.invokeMethod('placeDisable', {'forget': forget});
  static Future<void> placeRegister() => channel.invokeMethod('placeRegister');

  /// Announcement loudness boost: 0 off, 1 medium, 2 strong (default).
  static Future<Map<String, dynamic>> appInfo() async =>
      Map<String, dynamic>.from(
        await channel.invokeMapMethod<String, dynamic>('appInfo') ?? const {},
      );
  static Future<int> loudLevel() async =>
      await channel.invokeMethod<int>('loudLevel') ?? 2;
  static Future<void> setLoudLevel(int level) =>
      channel.invokeMethod('setLoudLevel', {'level': level});

  static Future<bool> dialNumber(String number) async =>
      await channel.invokeMethod<bool>('dialNumber', {'number': number}) ??
      false;
  static Future<bool> openMap(double lat, double lng) async =>
      await channel.invokeMethod<bool>('openMap', {'lat': lat, 'lng': lng}) ??
      false;

  static Future<bool> navigateTo(double lat, double lng) async =>
      await channel.invokeMethod<bool>('navigateTo', {
        'lat': lat,
        'lng': lng,
      }) ??
      false;
  static Future<Map<String, dynamic>> locationSnapshot() async =>
      Map<String, dynamic>.from(
        await channel.invokeMapMethod<String, dynamic>('locationSnapshot') ??
            const {},
      );
  static Future<Map<String, dynamic>> usageSnapshot() async =>
      Map<String, dynamic>.from(
        await channel.invokeMapMethod<String, dynamic>('usageSnapshot') ??
            const {},
      );

  /// Grandma's own agreement on this unlocked phone; [kind] is "location"
  /// or "usage". Returns false when she declined or it could not be shown.
  static Future<bool> sharingPrepareConsent(String kind) async =>
      await channel.invokeMethod<bool>('sharingPrepareConsent', {
        'kind': kind,
      }) ??
      false;
  static Future<void> sharingEnable(String kind, String hostUid, int version) =>
      channel.invokeMethod(
        kind == 'location' ? 'locationEnable' : 'usageEnable',
        {'hostUid': hostUid, 'version': version},
      );
  static Future<void> sharingDisable(String kind) => channel.invokeMethod(
    kind == 'location' ? 'locationDisable' : 'usageDisable',
  );
  static Future<void> locationRefresh() =>
      channel.invokeMethod('locationRefresh');
  static Future<void> openUsageAccessSettings() =>
      channel.invokeMethod('openUsageAccessSettings');
  static Future<String?> careReplay(String key) =>
      channel.invokeMethod<String>('careReplay', {'key': key});

  static Future<void> placeSetWorkName(String name) =>
      channel.invokeMethod('placeSetWorkName', {'name': name});
}
