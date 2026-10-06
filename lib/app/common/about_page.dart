// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
//
// The LICENSE requires this original-author credit to stay visible in every
// copy or derived work.
import 'package:flutter/material.dart';

import 'constants.dart';
import 'ui/fh_tokens.dart';
import 'ui/fh_widgets.dart';

class AboutPage extends StatelessWidget {
  final AppRole role;
  const AboutPage({super.key, required this.role});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final edition = role == AppRole.host ? '長輩版' : '家人版';
    return Scaffold(
      appBar: AppBar(title: const Text('關於')),
      body: ListView(
        padding: const EdgeInsets.all(FhSpace.lg),
        children: [
          FhCard(
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(FhSpace.lg),
                  decoration: const BoxDecoration(
                    color: FhColors.brandTint,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.family_restroom,
                    size: 48,
                    color: FhColors.brand,
                  ),
                ),
                const SizedBox(height: FhSpace.md),
                Text(
                  '${AppInfo.name} $edition',
                  key: const Key('about-title'),
                  style: text.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: FhSpace.xs),
                Text(
                  '經長輩每次同意的家人遠端協助',
                  style: text.bodyMedium?.copyWith(color: FhColors.inkMuted),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          const FhSectionHeader(title: '作者與授權'),
          FhCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: const Text('原作者'),
                  subtitle: Text(
                    AppInfo.author,
                    key: const Key('about-author'),
                  ),
                ),
                const Divider(indent: FhSpace.lg, endIndent: FhSpace.lg),
                ListTile(
                  leading: const Icon(Icons.copyright),
                  title: const Text('版權'),
                  subtitle: Text(AppInfo.copyright),
                ),
                const Divider(indent: FhSpace.lg, endIndent: FhSpace.lg),
                ListTile(
                  leading: const Icon(Icons.gavel_outlined),
                  title: const Text('授權'),
                  subtitle: Text(AppInfo.license),
                ),
                if (AppInfo.repository.isNotEmpty) ...[
                  const Divider(indent: FhSpace.lg, endIndent: FhSpace.lg),
                  ListTile(
                    leading: const Icon(Icons.code),
                    title: const Text('原始碼'),
                    subtitle: SelectableText(AppInfo.repository),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: FhSpace.lg),
          const FhStatusBanner(
            tone: FhTone.neutral,
            announce: false,
            message:
                '本軟體可免費供家庭自行建置、修改與使用；未經作者書面同意，'
                '不得上架任何應用程式商店或用於商業用途。',
          ),
          const SizedBox(height: FhSpace.lg),
          OutlinedButton.icon(
            onPressed: () => showLicensePage(
              context: context,
              applicationName: AppInfo.name,
              applicationLegalese: '${AppInfo.copyright}\n${AppInfo.license}',
            ),
            icon: const Icon(Icons.description_outlined),
            label: const Text('第三方套件授權'),
          ),
        ],
      ),
    );
  }
}
