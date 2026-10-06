// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';
import sharp from 'sharp';
import {sanitizePhotoData} from '../src/photo_media.js';

async function jpeg(width, height, options = {}) {
  let image = sharp({create: {width, height, channels: 3, background: '#749c84'}});
  if (options.exif) image = image.withExif({IFD0: {Copyright: 'private location hint'}});
  if (options.icc) image = image.withIccProfile('srgb');
  return image.jpeg().toBuffer();
}

test('accepts a square JPEG and removes all embedded metadata', async () => {
  const input = await jpeg(600, 600, {exif: true, icc: true});
  assert.ok((await sharp(input).metadata()).exif);
  assert.ok((await sharp(input).metadata()).icc);

  const result = await sanitizePhotoData(input.toString('base64'));
  const meta = await sharp(result.bytes).metadata();
  assert.equal(meta.format, 'jpeg');
  assert.equal(meta.width, 600);
  assert.equal(meta.height, 600);
  assert.equal(meta.exif, undefined);
  assert.equal(meta.icc, undefined);
  assert.ok(result.bytes.length <= 1_000_000);
  assert.match(result.sha256, /^[0-9a-f]{64}$/);
});

test('rejects malformed, noncanonical and oversized base64 before image parsing', async () => {
  for (const value of ['not/base64?', 'a', 'AB==', ' data', 'data:image/jpeg;base64,AA==', 'A'.repeat(1_333_340)]) {
    await assert.rejects(sanitizePhotoData(value), {code: 'invalid-argument'});
  }
});

test('rejects non-JPEG, nonsquare and oversized photos', async () => {
  const png = await sharp({create: {width: 200, height: 200, channels: 3, background: '#749c84'}}).png().toBuffer();
  const wide = await jpeg(400, 300);
  const large = await jpeg(1025, 1025);
  const corrupt = Buffer.from([0xff, 0xd8, 0x00, 0x01]);
  const byteLimit = Buffer.concat([await jpeg(100, 100), Buffer.alloc(1_000_001)]);
  for (const bytes of [png, wide, large, corrupt, byteLimit]) {
    await assert.rejects(sanitizePhotoData(bytes.toString('base64')), {code: 'invalid-argument'});
  }
});
