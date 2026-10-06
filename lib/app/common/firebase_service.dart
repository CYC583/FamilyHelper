// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'constants.dart';

Map<String, dynamic> asMap(Object? value) => value is Map
    ? value.map((key, value) => MapEntry(key.toString(), value))
    : <String, dynamic>{};

class FirebaseService {
  FirebaseService({String? databaseUrl})
    : _databaseUrl = databaseUrl ?? AppConfig.databaseUrl;

  final String _databaseUrl;

  FirebaseFunctions get functions =>
      FirebaseFunctions.instanceFor(region: AppConfig.region);
  FirebaseDatabase get database => FirebaseDatabase.instanceFor(
    app: Firebase.app(),
    databaseURL: _databaseUrl,
  );
  String get uid => FirebaseAuth.instance.currentUser!.uid;

  Future<void> start(AppRole role, String name) async {
    // Anonymous Auth supplies an unforgeable identity, without a login screen.
    if (FirebaseAuth.instance.currentUser == null) {
      await FirebaseAuth.instance.signInAnonymously();
    }
    await call('registerDevice', {'role': role.name, 'name': name});
  }

  Future<Map<String, dynamic>> call(
    String name, [
    Map<String, dynamic> data = const {},
  ]) async {
    final result = await functions.httpsCallable(name).call<dynamic>(data);
    return asMap(result.data);
  }

  Stream<Map<String, dynamic>> watch(String path) =>
      database.ref(path).onValue.map((e) => asMap(e.snapshot.value));

  /// One-time read; returns an empty map when the node is missing.
  Future<Map<String, dynamic>> read(String path) async =>
      asMap((await database.ref(path).get()).value);
  Stream<Map<String, dynamic>> family(String hostId) =>
      watch('core/families/$hostId');
  Stream<Map<String, dynamic>> session(String id) => watch('core/sessions/$id');
  Stream<Map<String, dynamic>> batteryEvents(String hostId) => database
      .ref('care/$hostId/battery/events')
      .orderByChild('createdAt')
      .limitToLast(50)
      .onValue
      .map((event) => asMap(event.snapshot.value));
  Future<void> end(String id, {bool reject = false}) async {
    await call('endHelp', {
      'sessionId': id,
      'reason': reject ? 'rejected' : 'ended',
    });
  }
}

String errorMessage(Object e) {
  if (e is FirebaseFunctionsException) {
    // A callable missing on the server (old backend) reports a bare code.
    if (e.code == 'not-found' && e.message == 'NOT_FOUND') {
      return '伺服器還沒更新這項功能，請稍後再試';
    }
    return e.message ?? '服務連線失敗，請重試';
  }
  if (e is FirebaseException) return '無法連接服務，請檢查網路與 Firebase 設定';
  return e
      .toString()
      .replaceFirst('Exception: ', '')
      .replaceFirst('Bad state: ', '');
}
