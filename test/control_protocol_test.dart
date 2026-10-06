// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:familyhelper/app/common/control_protocol.dart';

void main() {
  test('letterbox touches do not become screen taps', () {
    expect(
      normalizedPoint(
        const Offset(10, 100),
        const Size(400, 400),
        const Size(200, 400),
      ),
      isNull,
    );
    expect(
      normalizedPoint(
        const Offset(200, 200),
        const Size(400, 400),
        const Size(200, 400),
      ),
      const Offset(.5, .5),
    );
  });
  test('landscape fit maps bottom right correctly', () {
    expect(
      normalizedPoint(
        const Offset(400, 300),
        const Size(400, 400),
        const Size(400, 200),
      ),
      const Offset(1, 1),
    );
    expect(
      normalizedPoint(
        const Offset(200, 50),
        const Size(400, 400),
        const Size(400, 200),
      ),
      isNull,
    );
  });
  test('unrendered or invalid frames never map', () {
    expect(normalizedPoint(Offset.zero, const Size(10, 10), Size.zero), isNull);
    expect(
      normalizedPoint(
        const Offset(double.nan, 1),
        const Size(10, 10),
        const Size(10, 10),
      ),
      isNull,
    );
  });
  test(
    'gesture protocol rejects replay into another session and nonfinite coordinates',
    () {
      final data = <String, dynamic>{
        'type': 'tap',
        'sessionId': 'a',
        'seq': 1,
        'x': .5,
        'y': .5,
        'width': 100,
        'height': 200,
        'rotation': 0,
      };
      expect(validGesture(data, 'a'), isTrue);
      expect(validGesture(data, 'b'), isFalse);
      expect(validGesture({...data, 'x': double.nan}, 'a'), isFalse);
      expect(validGesture({...data, 'type': 'swipe'}, 'a'), isFalse);
    },
  );
}
