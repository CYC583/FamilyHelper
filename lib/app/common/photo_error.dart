// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/services.dart';

import 'firebase_service.dart';

String photoErrorMessage(Object error) {
  if (error is FormatException) return error.message;
  if (error is PlatformException) {
    return error.message?.isNotEmpty == true
        ? error.message!
        : '手機相簿暫時無法使用，請重試';
  }
  if (error is FirebaseFunctionsException && error.message == 'NOT_FOUND') {
    return '照片服務尚未開通，請稍後再試';
  }
  if (error is FirebaseFunctionsException &&
      error.code == 'not-found' &&
      (error.message == null || error.message!.isEmpty)) {
    return '照片不存在或已到期';
  }
  return errorMessage(error);
}
