// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import {createHash} from 'node:crypto';
import sharp from 'sharp';
import {Fault} from './state.js';

const MAX_PHOTO_BYTES = 1_000_000;
const MAX_PHOTO_SIDE = 1024;
const MAX_BASE64_LENGTH = Math.ceil(MAX_PHOTO_BYTES / 3) * 4;

function invalidPhoto() {
  return new Fault('invalid-argument', '照片需為正方形 JPEG，且不超過 1024 像素及 1 MB');
}

/** Never trust client-side resizing or metadata removal. Returns server-reencoded bytes. */
export async function sanitizePhotoData(base64) {
  if (typeof base64 !== 'string' || !base64 || base64.length > MAX_BASE64_LENGTH ||
    !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(base64)) {
    throw invalidPhoto();
  }
  const input = Buffer.from(base64, 'base64');
  if (!input.length || input.length > MAX_PHOTO_BYTES || input.toString('base64') !== base64 ||
    input[0] !== 0xff || input[1] !== 0xd8) throw invalidPhoto();

  try {
    const decoder = sharp(input, {failOn: 'error', limitInputPixels: MAX_PHOTO_SIDE ** 2});
    const metadata = await decoder.metadata();
    if (metadata.format !== 'jpeg' || metadata.pages > 1 || !metadata.width ||
      metadata.width !== metadata.height || metadata.width > MAX_PHOTO_SIDE) throw invalidPhoto();

    // sharp drops EXIF, ICC and other input metadata unless keepMetadata is called.
    const bytes = await decoder.jpeg({quality: 82, mozjpeg: true}).toBuffer();
    if (bytes.length > MAX_PHOTO_BYTES) throw invalidPhoto();
    return {
      bytes,
      width: metadata.width,
      height: metadata.height,
      sha256: createHash('sha256').update(bytes).digest('hex'),
    };
  } catch (error) {
    if (error instanceof Fault) throw error;
    throw invalidPhoto();
  }
}
