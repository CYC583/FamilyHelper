// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
//
// Design tokens shared by the elder (host) and family (client) apps.
// Every colour pair below keeps at least WCAG AA contrast (4.5:1) for text.
import 'package:flutter/material.dart';

/// Colour palette. Use these instead of literal `Color(0x...)` values so the
/// two apps stay visually consistent.
abstract final class FhColors {
  /// Primary brand green: "call family", selected tabs, positive actions.
  static const brand = Color(0xff125c49);
  static const brandDark = Color(0xff0c4335);
  static const brandSoft = Color(0xffdcefe7);
  static const brandTint = Color(0xffe6f2ea);

  /// Emergency / destructive red: SOS, stop sharing, failures.
  static const danger = Color(0xffa61f2a);
  static const dangerSoft = Color(0xffffe3e3);

  /// Attention amber: low battery, stale data, "check this".
  static const warning = Color(0xff8a3d00);
  static const warningSoft = Color(0xfffff4d6);

  /// Neutral information blue (connection notices, tips).
  static const info = Color(0xff1f4f8a);
  static const infoSoft = Color(0xffe3edfa);

  /// Text and surfaces.
  static const ink = Color(0xff17362c);
  static const inkMuted = Color(0xff53645b);
  static const outline = Color(0xffd5ddd8);
  static const surface = Color(0xffffffff);
  static const background = Color(0xfff8f6f0);
  static const onColor = Color(0xffffffff);
}

/// 4-point spacing scale.
abstract final class FhSpace {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

abstract final class FhRadius {
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 20.0;
  static const xl = 24.0;
}

/// Minimum touch target sizes. The elder app's primary actions must stay at
/// least 120dp tall (product rule), everything else at least 56dp.
abstract final class FhSize {
  static const elderPrimaryAction = 120.0;
  static const elderAction = 72.0;
  static const familyAction = 56.0;
}

/// Semantic tone for banners, chips and status text.
enum FhTone { neutral, info, success, warning, danger }

extension FhToneColors on FhTone {
  Color get foreground => switch (this) {
    FhTone.neutral => FhColors.inkMuted,
    FhTone.info => FhColors.info,
    FhTone.success => FhColors.brand,
    FhTone.warning => FhColors.warning,
    FhTone.danger => FhColors.danger,
  };

  Color get background => switch (this) {
    FhTone.neutral => const Color(0xfff0f2f0),
    FhTone.info => FhColors.infoSoft,
    FhTone.success => FhColors.brandTint,
    FhTone.warning => FhColors.warningSoft,
    FhTone.danger => FhColors.dangerSoft,
  };

  IconData get icon => switch (this) {
    FhTone.neutral => Icons.info_outline,
    FhTone.info => Icons.info_outline,
    FhTone.success => Icons.check_circle_outline,
    FhTone.warning => Icons.warning_amber_rounded,
    FhTone.danger => Icons.error_outline,
  };
}
