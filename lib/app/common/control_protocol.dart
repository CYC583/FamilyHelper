// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:ui';

/// Map only the visible image; touches in letterboxing are ignored.
Offset? normalizedPoint(Offset local, Size view, Size frame) {
  if (view.isEmpty || frame.isEmpty) return null;
  final scale = (view.width / frame.width < view.height / frame.height)
      ? view.width / frame.width
      : view.height / frame.height;
  final width = frame.width * scale, height = frame.height * scale;
  final left = (view.width - width) / 2, top = (view.height - height) / 2;
  final x = (local.dx - left) / width, y = (local.dy - top) / height;
  if (!x.isFinite || !y.isFinite || x < 0 || x > 1 || y < 0 || y > 1) {
    return null;
  }
  return Offset(x, y);
}

bool validGesture(Map<String, dynamic> m, String sessionId) {
  if (m['sessionId'] != sessionId ||
      !['tap', 'longPress', 'swipe'].contains(m['type'])) {
    return false;
  }
  bool coordinate(dynamic v) => v is num && v.isFinite && v >= 0 && v <= 1;
  if (!coordinate(m['x']) ||
      !coordinate(m['y']) ||
      m['seq'] is! int ||
      m['rotation'] is! int) {
    return false;
  }
  if (m['type'] == 'swipe' && (!coordinate(m['x2']) || !coordinate(m['y2']))) {
    return false;
  }
  return m['width'] is int && m['height'] is int;
}
