// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../common/firebase_service.dart';
import '../common/ui/fh_tokens.dart';
import '../common/ui/fh_widgets.dart';

class PairingClientPage extends StatefulWidget {
  final FirebaseService api;
  const PairingClientPage({super.key, required this.api});
  @override
  State<PairingClientPage> createState() => _PairingClientPageState();
}

class _PairingClientPageState extends State<PairingClientPage> {
  final name = TextEditingController(), code = TextEditingController();
  bool busy = false;
  String? error, nameError, codeError;
  Future<void> pair() async {
    final missingName = name.text.trim().isEmpty;
    final badCode = code.text.length != 6;
    if (missingName || badCode) {
      setState(() {
        nameError = missingName ? '請填寫長輩認得的名字' : null;
        codeError = badCode ? '配對碼是六位數字' : null;
        // Field errors sit next to the fields; no off-screen summary banner.
        error = null;
      });
      return;
    }
    setState(() {
      busy = true;
      error = nameError = codeError = null;
    });
    try {
      await widget.api.call('registerDevice', {
        'role': 'client',
        'name': name.text.trim(),
      });
      await (await SharedPreferences.getInstance()).setString(
        'deviceName',
        name.text.trim(),
      );
      await widget.api.call('pairDevice', {'code': code.text});
    } catch (e) {
      if (mounted) setState(() => error = errorMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    name.dispose();
    code.dispose();
    super.dispose();
  }

  Widget _step(BuildContext context, int n, String text) => Padding(
    padding: const EdgeInsets.only(bottom: FhSpace.sm),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 14,
          backgroundColor: FhColors.brand,
          foregroundColor: FhColors.onColor,
          child: Text('$n', style: const TextStyle(fontSize: 14)),
        ),
        const SizedBox(width: FhSpace.md),
        Expanded(child: Text(text)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('連結長輩手機')),
    body: ListView(
      padding: const EdgeInsets.all(FhSpace.xl),
      children: [
        FhCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('怎麼配對', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: FhSpace.md),
              const Text('請長輩或陪同家人開啟設定，產生配對碼。'),
              const SizedBox(height: FhSpace.md),
              _step(context, 1, '在長輩手機按右上角齒輪「家人設定」→「產生配對碼」'),
              _step(context, 2, '在下面輸入你的名字和那六位數字'),
              _step(context, 3, '按「配對」，完成後就能看到長輩的狀態'),
            ],
          ),
        ),
        const SizedBox(height: FhSpace.xl),
        TextField(
          controller: name,
          maxLength: 24,
          textInputAction: TextInputAction.next,
          onChanged: (_) {
            if (nameError != null) setState(() => nameError = null);
          },
          decoration: InputDecoration(
            labelText: '你的名字（例如：小明、姊姊）',
            helperText: '長輩會看到這個稱呼',
            errorText: nameError,
            prefixIcon: const Icon(Icons.person_outline),
          ),
        ),
        const SizedBox(height: FhSpace.lg),
        TextField(
          controller: code,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          onChanged: (_) {
            if (codeError != null) setState(() => codeError = null);
          },
          onSubmitted: (_) => busy ? null : pair(),
          style: const TextStyle(
            fontSize: 36,
            letterSpacing: 8,
            fontWeight: FontWeight.bold,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
          decoration: InputDecoration(
            labelText: '六位數配對碼',
            hintText: '000000',
            errorText: codeError,
          ),
        ),
        const SizedBox(height: FhSpace.xl),
        FilledButton(
          onPressed: busy ? null : pair,
          child: busy
              ? const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: FhColors.onColor,
                      ),
                    ),
                    SizedBox(width: FhSpace.md),
                    Text('配對中…'),
                  ],
                )
              : const Text('配對'),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: FhSpace.lg),
            child: FhStatusBanner(
              key: const Key('pair-error'),
              tone: FhTone.danger,
              message: error!,
            ),
          ),
      ],
    ),
  );
}
