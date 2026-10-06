// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:familyhelper/app/host/photo_processing.dart';

void main() {
  test('分享前輸出正方形 JPEG，限制像素與檔案大小', () {
    final source = img.Image(width: 1400, height: 1400);
    img.fill(source, color: img.ColorRgb8(36, 116, 85));

    final result = preparePhotoForSharing(
      Uint8List.fromList(img.encodePng(source)),
    );

    expect(result.length, lessThanOrEqualTo(1000000));
    expect(result.take(2), [0xff, 0xd8]);
    final output = img.decodeJpg(result)!;
    expect(output.width, 1024);
    expect(output.height, 1024);
  });

  test('移除原始 JPEG 的 EXIF、GPS 與文字標記', () {
    final source = img.Image(width: 4, height: 4);
    source.exif.imageIfd[0x010e] = img.IfdValueAscii('私人照片說明');
    source.exif.gpsIfd[0x0001] = img.IfdValueAscii('N');
    final original = Uint8List.fromList(img.encodeJpg(source));
    expect(img.decodeJpg(original)!.exif.isEmpty, isFalse);

    final result = preparePhotoForSharing(original);
    expect(img.decodeJpg(result)!.exif.isEmpty, isTrue);
    expect(result.length, lessThanOrEqualTo(1000000));
  });

  test('損毀或非正方形照片不會被當成可分享照片', () {
    expect(
      () => preparePhotoForSharing(Uint8List.fromList([1, 2, 3])),
      throwsStateError,
    );
    final rectangle = img.Image(width: 8, height: 4);
    expect(
      () =>
          preparePhotoForSharing(Uint8List.fromList(img.encodePng(rectangle))),
      throwsStateError,
    );
  });
}
