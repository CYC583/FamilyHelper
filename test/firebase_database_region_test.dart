// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:familyhelper/app/common/firebase_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();

  setUpAll(() async {
    await Firebase.initializeApp();
  });

  test(
    'database requests use the configured regional URL, not native default',
    () {
      const regionalUrl =
          'https://test-project-default-rtdb.asia-southeast1.firebasedatabase.app';
      final database = FirebaseService(databaseUrl: regionalUrl).database;

      expect(database.databaseURL, regionalUrl);
    },
  );
}
