// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:typed_data';

import 'package:image/image.dart' as img;

const maxSharedPhotoBytes = 1000000;
const maxSharedPhotoSide = 1024;
const _maxSourceBytes = 16 * 1024 * 1024;

/// Prepares only the already-cropped 1:1 camera result for an explicit share.
/// Re-encoding drops camera EXIF (including GPS), comments and ICC metadata.
/// This does not upload or persist the photo.
Uint8List preparePhotoForSharing(Uint8List source) {
  if (source.isEmpty || source.length > _maxSourceBytes) {
    throw StateError('照片太大或無法讀取，請重新拍照');
  }
  img.Image? decoded;
  try {
    decoded = img.decodeImage(source);
  } catch (_) {
    throw StateError('照片無法讀取，請重新拍照');
  }
  if (decoded == null || decoded.width == 0 || decoded.height == 0) {
    throw StateError('照片無法讀取，請重新拍照');
  }
  if (decoded.width != decoded.height) {
    throw StateError('照片不是正方形，請重新拍照');
  }

  var side = decoded.width > maxSharedPhotoSide
      ? maxSharedPhotoSide
      : decoded.width;
  while (true) {
    final photo = side == decoded.width
        ? decoded
        : img.copyResize(decoded, width: side, height: side);
    // The JPEG encoder preserves EXIF and ICC unless explicitly removed.
    photo.exif = img.ExifData();
    photo.iccProfile = null;
    for (final quality in [82, 72, 62]) {
      final bytes = Uint8List.fromList(
        img.encodeJpg(photo, quality: quality, chroma: img.JpegChroma.yuv420),
      );
      if (bytes.length <= maxSharedPhotoBytes) return bytes;
    }
    if (side <= 384) {
      throw StateError('照片無法縮小到分享上限，請重新拍照');
    }
    side = (side * 0.8).floor();
    if (side < 384) side = 384;
  }
}
