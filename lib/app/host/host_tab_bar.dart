// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:flutter/material.dart';

import '../common/ui/fh_tokens.dart';

/// Elder-app bottom navigation. Larger than Material's NavigationBar: 88dp
/// tall, 30dp icons and labels that keep growing with system text size.
class HostTabBar extends StatelessWidget {
  /// Tab ids: 0 求助, 1 今天, 2 照片, 3 家人.
  final int selected;
  final int chatUnread;
  final ValueChanged<int> onSelect;

  const HostTabBar({
    super.key,
    required this.selected,
    required this.chatUnread,
    required this.onSelect,
  });

  static const tabs = [
    (0, '求助', Icons.favorite_border, Icons.favorite),
    (1, '今天', Icons.wb_sunny_outlined, Icons.wb_sunny),
    (3, '家人', Icons.forum_outlined, Icons.forum),
    (2, '照片', Icons.photo_camera_outlined, Icons.photo_camera),
  ];

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: FhColors.surface,
      border: Border(top: BorderSide(color: FhColors.outline)),
    ),
    child: SafeArea(
      top: false,
      // Labels stay large (up to ~29sp) without pushing the bar taller.
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.6,
        child: SizedBox(
          height: 88,
          child: Row(
            children: [
              for (final (index, label, icon, activeIcon) in tabs)
                Expanded(
                  child: _HostTab(
                    label: label,
                    icon: selected == index ? activeIcon : icon,
                    on: selected == index,
                    unread: index == 3 ? chatUnread : 0,
                    onTap: () => onSelect(index),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _HostTab extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool on;
  final int unread;
  final VoidCallback onTap;

  const _HostTab({
    required this.label,
    required this.icon,
    required this.on,
    required this.unread,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = on ? FhColors.brand : FhColors.inkMuted;
    return Semantics(
      selected: on,
      button: true,
      label: unread > 0 ? '$label，$unread 則新留言' : label,
      excludeSemantics: true,
      child: InkWell(
        key: Key('host-tab-$label'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(FhRadius.md),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          decoration: BoxDecoration(
            color: on ? FhColors.brandSoft : Colors.transparent,
            border: on ? Border.all(color: FhColors.brand, width: 2) : null,
            borderRadius: BorderRadius.circular(FhRadius.md),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Badge(
                key: Key('host-badge-$label'),
                isLabelVisible: unread > 0,
                backgroundColor: FhColors.danger,
                label: Text(
                  unread > 9 ? '9+' : '$unread',
                  style: const TextStyle(fontSize: 14),
                ),
                child: Icon(icon, size: 30, color: color),
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: on ? FontWeight.bold : FontWeight.w500,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
