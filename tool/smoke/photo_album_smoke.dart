// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
// Emulator-only native MediaStore smoke test; never used as a release entrypoint.
import 'dart:typed_data';

import 'package:familyhelper/app/common/native_bridge.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

void main() => runApp(const MaterialApp(home: _SmokePage()));

class _SmokePage extends StatefulWidget {
  const _SmokePage();

  @override
  State<_SmokePage> createState() => _SmokePageState();
}

class _SmokePageState extends State<_SmokePage> {
  String status = '正在儲存模擬器測試照片…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _save());
  }

  Future<void> _save() async {
    final image = img.Image(width: 64, height: 64);
    img.fill(image, color: img.ColorRgb8(18, 92, 73));
    final jpeg = Uint8List.fromList(img.encodeJpg(image));
    try {
      final saved = await NativeBridge.savePhotoToAlbum(jpeg);
      if (mounted) setState(() => status = saved ? '測試照片已儲存' : '手機未確認儲存');
    } catch (error) {
      if (mounted) setState(() => status = '儲存失敗：$error');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('相簿寫入測試')),
    body: Center(child: Text(status, textAlign: TextAlign.center)),
  );
}
