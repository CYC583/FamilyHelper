// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'firebase_service.dart';
import 'photo_loader.dart';
import 'ui/fh_tokens.dart';

/// A square photo that downloads only when it is actually built on screen.
class PhotoThumb extends StatefulWidget {
  final FirebaseService api;
  final String hostId;
  final CarePhoto photo;
  const PhotoThumb({
    super.key,
    required this.api,
    required this.hostId,
    required this.photo,
  });

  @override
  State<PhotoThumb> createState() => _PhotoThumbState();
}

class _PhotoThumbState extends State<PhotoThumb> {
  Uint8List? bytes;
  bool failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PhotoThumb old) {
    super.didUpdateWidget(old);
    if (old.photo.mediaId != widget.photo.mediaId) _load();
  }

  Future<void> _load() async {
    final id = widget.photo.mediaId;
    setState(() {
      bytes = PhotoLoader.cached(widget.hostId, id);
      failed = false;
    });
    if (bytes != null) return;
    try {
      final b = await PhotoLoader.load(widget.api, widget.hostId, id);
      if (mounted && widget.photo.mediaId == id) setState(() => bytes = b);
    } catch (_) {
      if (mounted && widget.photo.mediaId == id) setState(() => failed = true);
    }
  }

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 1,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: ColoredBox(
        color: FhColors.brandTint,
        child: bytes != null
            ? Image.memory(
                bytes!,
                fit: BoxFit.cover,
                cacheWidth: 400,
                gaplessPlayback: true,
              )
            : Center(
                child: Icon(
                  failed ? Icons.broken_image_outlined : Icons.photo_outlined,
                  size: 36,
                  color: FhColors.inkMuted,
                ),
              ),
      ),
    ),
  );
}
