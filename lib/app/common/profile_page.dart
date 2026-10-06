// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import 'firebase_service.dart';
import 'ui/fh_tokens.dart';

/// Picks a photo: "camera" or "gallery". Returns the raw bytes or null.
typedef PhotoPicker = Future<Uint8List?> Function(String source);

Future<Uint8List?> defaultPhotoPicker(String source) async {
  final file = await ImagePicker().pickImage(
    source: source == 'camera' ? ImageSource.camera : ImageSource.gallery,
    maxWidth: 1024,
    maxHeight: 1024,
    imageQuality: 90,
    preferredCameraDevice: CameraDevice.front,
  );
  return file?.readAsBytes();
}

/// Center-cropped square JPEG, 192px, small enough for the database.
String? avatarBase64(Uint8List raw) {
  final decoded = img.decodeImage(raw);
  if (decoded == null) return null;
  final oriented = img.bakeOrientation(decoded);
  final side = oriented.width < oriented.height
      ? oriented.width
      : oriented.height;
  final square = img.copyCrop(
    oriented,
    x: (oriented.width - side) ~/ 2,
    y: (oriented.height - side) ~/ 2,
    width: side,
    height: side,
  );
  final small = img.copyResize(square, width: 192, height: 192);
  for (final quality in [85, 70, 55]) {
    final encoded = base64Encode(img.encodeJpg(small, quality: quality));
    if (encoded.length <= 58_000) return encoded;
  }
  return null;
}

/// A round photo, or the first character of the name.
class AvatarCircle extends StatelessWidget {
  final String? base64Jpeg;
  final String name;
  final double radius;
  const AvatarCircle({
    super.key,
    required this.base64Jpeg,
    required this.name,
    this.radius = 28,
  });

  @override
  Widget build(BuildContext context) {
    Uint8List? bytes;
    try {
      if (base64Jpeg != null) bytes = base64Decode(base64Jpeg!);
    } catch (_) {}
    return CircleAvatar(
      radius: radius,
      backgroundColor: FhColors.brandSoft,
      foregroundImage: bytes == null ? null : MemoryImage(bytes),
      child: Text(
        name.isEmpty ? '?' : name.characters.first,
        style: TextStyle(
          fontSize: radius * 0.8,
          color: FhColors.brand,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// Change this phone's own display name and photo. Shown to the rest of the
/// family; the server re-checks length and format.
class ProfilePage extends StatefulWidget {
  final FirebaseService api;
  final String hostId;
  final String currentName;
  final bool large;
  final PhotoPicker pick;
  const ProfilePage({
    super.key,
    required this.api,
    required this.hostId,
    required this.currentName,
    this.large = false,
    this.pick = defaultPhotoPicker,
  });

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late final name = TextEditingController(text: widget.currentName);
  StreamSubscription<Map<String, dynamic>>? _sub;
  String? savedAvatar, pendingAvatar, status;
  bool removeAvatar = false, busy = false, statusError = false;

  @override
  void initState() {
    super.initState();
    try {
      _sub = widget.api
          .watch('avatars/${widget.hostId}/${widget.api.uid}')
          .listen(
            (v) => setState(() => savedAvatar = v['jpegBase64'] as String?),
            onError: (_) {},
          );
    } catch (_) {}
  }

  @override
  void dispose() {
    _sub?.cancel();
    name.dispose();
    super.dispose();
  }

  Future<void> _choose(String source) async {
    try {
      final raw = await widget.pick(source);
      if (raw == null || !mounted) return;
      final encoded = avatarBase64(raw);
      setState(() {
        if (encoded == null) {
          status = '這張照片無法使用，請換一張';
          statusError = true;
        } else {
          pendingAvatar = encoded;
          removeAvatar = false;
          status = '還沒儲存，按「儲存」才會換';
          statusError = false;
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          status = '沒有拿到照片：${errorMessage(e)}';
          statusError = true;
        });
      }
    }
  }

  Future<void> _save() async {
    final text = name.text.trim();
    if (text.isEmpty || text.length > 12 || text.contains(RegExp(r'[<>]'))) {
      setState(() {
        status = '名字請在 12 個字內，不要輸入 < >';
        statusError = true;
      });
      return;
    }
    setState(() {
      busy = true;
      status = '正在儲存…';
      statusError = false;
    });
    try {
      await widget.api.call('setProfile', {
        if (text != widget.currentName) 'name': text,
        if (pendingAvatar != null) 'avatarBase64': pendingAvatar,
        if (removeAvatar) 'removeAvatar': true,
      });
      if (!mounted) return;
      setState(() {
        if (pendingAvatar != null) savedAvatar = pendingAvatar;
        if (removeAvatar) savedAvatar = null;
        pendingAvatar = null;
        removeAvatar = false;
        status = '已儲存，家人會看到新的名字和頭貼';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          status = '沒有儲存，請再按一次：${errorMessage(e)}';
          statusError = true;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.large ? 22.0 : 17.0;
    final shown = removeAvatar ? null : pendingAvatar ?? savedAvatar;
    final buttonHeight = widget.large ? 64.0 : 48.0;
    return Scaffold(
      appBar: AppBar(title: const Text('我的名字與頭貼')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(
            child: AvatarCircle(
              key: const Key('profile-avatar'),
              base64Jpeg: shown,
              name: name.text,
              radius: widget.large ? 72 : 56,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const Key('profile-camera'),
                style: OutlinedButton.styleFrom(
                  minimumSize: Size(150, buttonHeight),
                ),
                onPressed: busy ? null : () => _choose('camera'),
                icon: const Icon(Icons.photo_camera_outlined),
                label: Text('拍一張', style: TextStyle(fontSize: size)),
              ),
              OutlinedButton.icon(
                key: const Key('profile-gallery'),
                style: OutlinedButton.styleFrom(
                  minimumSize: Size(150, buttonHeight),
                ),
                onPressed: busy ? null : () => _choose('gallery'),
                icon: const Icon(Icons.photo_library_outlined),
                label: Text('從相簿選', style: TextStyle(fontSize: size)),
              ),
              if (shown != null)
                TextButton(
                  onPressed: busy
                      ? null
                      : () => setState(() {
                          pendingAvatar = null;
                          removeAvatar = true;
                          status = '還沒儲存，按「儲存」才會移除';
                          statusError = false;
                        }),
                  child: Text('不用頭貼', style: TextStyle(fontSize: size)),
                ),
            ],
          ),
          const SizedBox(height: 20),
          TextField(
            key: const Key('profile-name'),
            controller: name,
            maxLength: 12,
            style: TextStyle(fontSize: size + 2),
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: '我的名字（家人看到的稱呼）'),
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('profile-save'),
            style: FilledButton.styleFrom(
              minimumSize: Size.fromHeight(buttonHeight + 8),
            ),
            onPressed: busy ? null : _save,
            child: Text('儲存', style: TextStyle(fontSize: size + 2)),
          ),
          if (status != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                status!,
                style: TextStyle(
                  fontSize: size,
                  color: statusError ? FhColors.danger : FhColors.brand,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
