// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../common/firebase_service.dart';
import '../common/native_bridge.dart';

class HealthConnectService {
  final FirebaseService api;
  HealthConnectService(this.api);
  Future<bool> get enabled async =>
      (await SharedPreferences.getInstance()).getBool('healthEnabled') ?? false;
  Future<void> enable() async {
    final available =
        await NativeBridge.channel.invokeMethod<bool>('healthStatus') ?? false;
    if (!available) {
      throw PlatformException(
        code: 'HEALTH_UNAVAILABLE',
        message: 'Health Connect 尚未準備好',
      );
    }
    final granted =
        await NativeBridge.channel.invokeMethod<bool>('healthPermission') ??
        false;
    if (!granted) throw Exception('健康資料權限尚未允許');
    await (await SharedPreferences.getInstance()).setBool(
      'healthEnabled',
      true,
    );
  }

  Future<void> disable() async {
    await (await SharedPreferences.getInstance()).setBool(
      'healthEnabled',
      false,
    );
    await api.call('clearHealth');
  }

  Future<void> sync() async {
    if (!await enabled) return;
    final data = asMap(await NativeBridge.channel.invokeMethod('readHealth'));
    final prefs = await SharedPreferences.getInstance();
    final thresholds = <String, dynamic>{};
    for (final key in ['heartLow', 'heartHigh', 'oxygenLow']) {
      final value = prefs.getDouble(key);
      if (value != null) thresholds[key] = value;
    }
    await api.call('submitHealth', {'data': data, 'thresholds': thresholds});
  }
}
