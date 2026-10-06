// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:cloud_functions/cloud_functions.dart';
import 'package:familyhelper/app/host/photo_error.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('已到期照片的 not-found 不得說成整個照片服務未開通', () {
    final message = photoErrorMessage(
      FirebaseFunctionsException(code: 'not-found', message: '照片不存在或已到期'),
    );
    expect(message, '照片不存在或已到期');
  });

  test('未部署照片 Callable 的裸 NOT_FOUND 要說清楚服務尚未開通', () {
    final message = photoErrorMessage(
      FirebaseFunctionsException(code: 'not-found', message: 'NOT_FOUND'),
    );
    expect(message, '照片服務尚未開通，請稍後再試');
  });
}
