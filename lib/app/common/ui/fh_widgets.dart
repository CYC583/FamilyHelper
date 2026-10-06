// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
//
// Small, reusable building blocks so every screen shows loading, empty,
// error and status feedback the same way.
import 'package:flutter/material.dart';

import 'fh_tokens.dart';

/// Inline coloured message with an icon. Use for connection notices,
/// "waiting for consent" hints, warnings and errors.
class FhStatusBanner extends StatelessWidget {
  final String message;
  final String? title;
  final FhTone tone;
  final Widget? action;
  final bool announce;

  const FhStatusBanner({
    super.key,
    required this.message,
    this.title,
    this.tone = FhTone.info,
    this.action,
    this.announce = true,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final fg = tone.foreground;
    return Semantics(
      liveRegion: announce,
      container: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(FhSpace.lg),
        decoration: BoxDecoration(
          color: tone.background,
          borderRadius: BorderRadius.circular(FhRadius.md),
          border: Border.all(color: fg.withValues(alpha: 0.25)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(child: Icon(tone.icon, color: fg, size: 28)),
            const SizedBox(width: FhSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null) ...[
                    Text(title!, style: text.titleMedium?.copyWith(color: fg)),
                    const SizedBox(height: FhSpace.xs),
                  ],
                  Text(
                    message,
                    style: text.bodyMedium?.copyWith(color: FhColors.ink),
                  ),
                  if (action != null) ...[
                    const SizedBox(height: FhSpace.sm),
                    action!,
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Centered placeholder for lists or panels that have no content yet.
/// Always tells the user *why* it is empty and, when possible, what to do.
class FhEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  const FhEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(FhSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(FhSpace.lg),
              decoration: const BoxDecoration(
                color: FhColors.brandTint,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 40, color: FhColors.brand),
            ),
            const SizedBox(height: FhSpace.lg),
            Text(title, textAlign: TextAlign.center, style: text.titleLarge),
            if (message != null) ...[
              const SizedBox(height: FhSpace.sm),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(color: FhColors.inkMuted),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: FhSpace.xl),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Full-area loading indicator with a short, human-readable label.
class FhLoadingView extends StatelessWidget {
  final String label;
  const FhLoadingView({super.key, this.label = '讀取中…'});

  @override
  Widget build(BuildContext context) => Center(
    child: Semantics(
      liveRegion: true,
      label: label,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox.square(
            dimension: 48,
            child: CircularProgressIndicator(strokeWidth: 4),
          ),
          const SizedBox(height: FhSpace.lg),
          ExcludeSemantics(
            child: Text(label, style: Theme.of(context).textTheme.bodyLarge),
          ),
        ],
      ),
    ),
  );
}

/// Full-area error with an explanation and a retry button.
class FhErrorView extends StatelessWidget {
  final String title;
  final String message;
  final VoidCallback? onRetry;
  final String retryLabel;
  final Widget? extra;

  const FhErrorView({
    super.key,
    this.title = '發生問題',
    required this.message,
    this.onRetry,
    this.retryLabel = '重試',
    this.extra,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(FhSpace.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(FhSpace.lg),
                decoration: const BoxDecoration(
                  color: FhColors.dangerSoft,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.error_outline,
                  size: 40,
                  color: FhColors.danger,
                ),
              ),
              const SizedBox(height: FhSpace.lg),
              Text(title, textAlign: TextAlign.center, style: text.titleLarge),
              const SizedBox(height: FhSpace.sm),
              Semantics(
                liveRegion: true,
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: text.bodyLarge,
                ),
              ),
              if (extra != null) ...[
                const SizedBox(height: FhSpace.lg),
                extra!,
              ],
              if (onRetry != null) ...[
                const SizedBox(height: FhSpace.xl),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: Text(retryLabel),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Section heading used inside scrolling settings / status pages.
class FhSectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;

  const FhSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FhSpace.xs,
        FhSpace.xl,
        FhSpace.xs,
        FhSpace.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(title, style: text.titleMedium),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: FhSpace.xs),
                    child: Text(subtitle!, style: text.bodySmall),
                  ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// White rounded panel with consistent padding.
class FhCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  const FhCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(FhSpace.lg),
    this.onTap,
  });

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(padding: padding, child: child),
    ),
  );
}
