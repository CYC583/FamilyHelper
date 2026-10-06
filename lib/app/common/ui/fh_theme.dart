// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:flutter/material.dart';

import '../constants.dart';
import 'fh_tokens.dart';

/// Builds the Material theme for one app role.
///
/// The elder app uses a larger type scale and taller controls; the family app
/// is denser so status lists and settings stay scannable.
ThemeData buildFhTheme(AppRole role) {
  final elder = role == AppRole.host;
  final scheme = ColorScheme.fromSeed(
    seedColor: FhColors.brand,
    primary: FhColors.brand,
    onPrimary: FhColors.onColor,
    error: FhColors.danger,
    onError: FhColors.onColor,
    surface: FhColors.surface,
    onSurface: FhColors.ink,
    onSurfaceVariant: FhColors.inkMuted,
    outline: FhColors.outline,
  );
  final body = elder ? 24.0 : 18.0;
  final text = TextTheme(
    headlineMedium: TextStyle(
      fontSize: elder ? 32 : 26,
      fontWeight: FontWeight.w700,
      height: 1.25,
    ),
    headlineSmall: TextStyle(
      fontSize: elder ? 28 : 22,
      fontWeight: FontWeight.w700,
      height: 1.3,
    ),
    titleLarge: TextStyle(
      fontSize: elder ? 26 : 20,
      fontWeight: FontWeight.w700,
      height: 1.3,
    ),
    titleMedium: TextStyle(
      fontSize: elder ? 22 : 17,
      fontWeight: FontWeight.w600,
      height: 1.35,
    ),
    bodyLarge: TextStyle(fontSize: body, height: 1.45),
    bodyMedium: TextStyle(fontSize: elder ? 20 : 16, height: 1.45),
    bodySmall: TextStyle(
      fontSize: elder ? 18 : 14,
      height: 1.4,
      color: FhColors.inkMuted,
    ),
    labelLarge: TextStyle(
      fontSize: elder ? 24 : 17,
      fontWeight: FontWeight.w700,
    ),
  ).apply(bodyColor: FhColors.ink, displayColor: FhColors.ink);

  final actionHeight = elder ? FhSize.elderAction : FhSize.familyAction;
  final roundedMd = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(FhRadius.md),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: FhColors.background,
    textTheme: text,
    visualDensity: VisualDensity.standard,
    appBarTheme: AppBarTheme(
      backgroundColor: FhColors.background,
      foregroundColor: FhColors.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 1,
      centerTitle: false,
      titleTextStyle: text.titleLarge,
    ),
    cardTheme: CardThemeData(
      color: FhColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FhRadius.lg),
        side: const BorderSide(color: FhColors.outline),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: Size(64, actionHeight),
        textStyle: text.labelLarge,
        shape: roundedMd,
        padding: const EdgeInsets.symmetric(horizontal: FhSpace.xl),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: Size(64, actionHeight),
        textStyle: text.labelLarge,
        foregroundColor: FhColors.brand,
        side: const BorderSide(color: FhColors.brand, width: 1.5),
        shape: roundedMd,
        padding: const EdgeInsets.symmetric(horizontal: FhSpace.xl),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        foregroundColor: FhColors.brand,
        textStyle: text.titleMedium,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: FhColors.surface,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: FhSpace.lg,
        vertical: FhSpace.lg,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(FhRadius.sm),
        borderSide: const BorderSide(color: FhColors.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(FhRadius.sm),
        borderSide: const BorderSide(color: FhColors.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(FhRadius.sm),
        borderSide: const BorderSide(color: FhColors.brand, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(FhRadius.sm),
        borderSide: const BorderSide(color: FhColors.danger, width: 1.5),
      ),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: FhSpace.lg),
      minVerticalPadding: FhSpace.md,
      iconColor: FhColors.brand,
      titleTextStyle: text.titleMedium,
      subtitleTextStyle: text.bodySmall,
    ),
    dividerTheme: const DividerThemeData(
      color: FhColors.outline,
      thickness: 1,
      space: 1,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: FhColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FhRadius.xl),
      ),
      titleTextStyle: text.headlineSmall,
      contentTextStyle: text.bodyLarge,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: FhColors.ink,
      contentTextStyle: TextStyle(
        fontSize: elder ? 20 : 16,
        color: FhColors.onColor,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FhRadius.sm),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: FhColors.surface,
      indicatorColor: FhColors.brandSoft,
      surfaceTintColor: Colors.transparent,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 14,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? FhColors.brand
              : FhColors.inkMuted,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? FhColors.brand
              : FhColors.inkMuted,
        ),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? FhColors.onColor : null,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? FhColors.brand : null,
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: FhColors.brand,
    ),
  );
}
