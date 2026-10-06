// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:flutter/material.dart';
import 'constants.dart';
import 'ui/fh_tokens.dart';

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key, required this.role, required this.onDone});

  final AppRole role;
  final Future<void> Function() onDone;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _GuideStep {
  const _GuideStep(this.title, this.detail, this.icon);

  final String title;
  final String detail;
  final IconData icon;
}

class _OnboardingPageState extends State<OnboardingPage> {
  int step = 0;
  bool saving = false;
  String? error;

  static const hostSteps = [
    _GuideStep('綠色：呼叫家人', '按下後會顯示通知進度。', Icons.call_outlined),
    _GuideStep('紅色：SOS 緊急求助', '會嘗試通知家人，但不等於報案。', Icons.emergency_outlined),
    _GuideStep('照片就在下方', '點「照片」拍照，分享前會先問你。', Icons.photo_camera_outlined),
    _GuideStep('協助由你決定', '每次都要你同意，隨時可以停止。', Icons.pan_tool_outlined),
  ];
  static const clientSteps = [
    _GuideStep('先與長輩配對', '輸入長輩手機顯示的六位數配對碼。', Icons.link_outlined),
    _GuideStep('常用功能在下方', '守護、陪伴、照片、協助都有固定入口。', Icons.dashboard_outlined),
    _GuideStep('開啟重要通知', '稍後會詢問手機通知權限；不能保證每次送達。', Icons.notifications_outlined),
    _GuideStep('每次都要長輩同意', '遠端協助不能代按長輩的同意或系統權限。', Icons.verified_user_outlined),
  ];

  Future<void> finish() async {
    if (saving) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.onDone();
    } catch (_) {
      if (mounted) {
        setState(() {
          saving = false;
          error = '無法記住指引進度，請再試一次。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final elder = widget.role == AppRole.host;
    final steps = elder ? hostSteps : clientSteps;
    final item = steps[step];
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    return Scaffold(
      backgroundColor: FhColors.background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxHeight < 640 || textScale >= 1.7;
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Padding(
                  padding: EdgeInsets.all(compact ? 12 : 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        elder ? '長輩版使用指引' : '家人版使用指引',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                          color: FhColors.ink,
                        ),
                      ),
                      Text(
                        '${step + 1}／${steps.length}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 16),
                      ),
                      Expanded(
                        child: Center(
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (!compact) ...[
                                  Icon(
                                    item.icon,
                                    size: 56,
                                    color: FhColors.brand,
                                  ),
                                  const SizedBox(height: 20),
                                ],
                                Text(
                                  item.title,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 28,
                                    fontWeight: FontWeight.bold,
                                    color: FhColors.ink,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  item.detail,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(fontSize: 22),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (!compact)
                        const Text(
                          '指引不會替你開啟通知、相機、遠端操作或系統權限。',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 14),
                        ),
                      if (error != null)
                        Text(
                          error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: FhColors.danger),
                        ),
                      const SizedBox(height: 8),
                      FilledButton(
                        key: const Key('onboarding-next'),
                        onPressed: saving
                            ? null
                            : step == steps.length - 1
                            ? finish
                            : () => setState(() => step++),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(64),
                          backgroundColor: FhColors.brand,
                        ),
                        child: Text(
                          saving
                              ? '準備中…'
                              : step == steps.length - 1
                              ? '開始使用'
                              : '下一步',
                        ),
                      ),
                      TextButton(
                        key: const Key('onboarding-skip'),
                        onPressed: saving ? null : finish,
                        child: const Text('先略過'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
