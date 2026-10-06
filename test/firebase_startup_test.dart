// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:familyhelper/app/common/bootstrap.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();

  test('startup reuses the Android native default Firebase app', () async {
    final first = await ensureFirebaseInitialized();
    final second = await ensureFirebaseInitialized();

    expect(first.name, defaultFirebaseAppName);
    expect(second.name, defaultFirebaseAppName);
    expect(Firebase.apps, hasLength(1));
  });
}
