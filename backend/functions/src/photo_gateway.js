// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import {createHash, randomUUID} from 'node:crypto';
import {Fault, rate} from './state.js';
import * as photos from './photo_state.js';
import {sanitizePhotoData} from './photo_media.js';

const MAX_CLEANUP_BATCH = 100;
const MAX_OBJECT_BYTES = 1_000_000;
const FAMILY_DOWNLOAD_LIMIT = 1500;
const THIRTY_DAYS_MS = 30 * 24 * 60 * 60_000;

function requiredId(value) {
  if (typeof value !== 'string' || !/^[a-zA-Z0-9-]{1,128}$/.test(value)) {
    throw new Fault('invalid-argument', '照片識別碼無效');
  }
  return value;
}

function publicPhoto(op) {
  return {mediaId: op.mediaId, day: op.day, createdAt: op.createdAt};
}

function digest(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

/** The bucket is private; callers never receive an object path or download URL. */
export function createPhotoGateway({readCore, atomic, bucket, now = Date.now, newId = randomUUID}) {
  async function verifiedBytes(op) {
    let bytes;
    try { [bytes] = await bucket.file(op.objectPath).download(); }
    catch { throw new Fault('failed-precondition', '照片檔案暫時無法使用'); }
    if (!Buffer.isBuffer(bytes) || bytes.length > MAX_OBJECT_BYTES || digest(bytes) !== op.sha256) {
      throw new Fault('data-loss', '照片檔案驗證失敗');
    }
    return bytes;
  }

  return {
    async setConsent(uid, enabled) {
      const s = await atomic(current => photos.setPhotoConsent(current, uid, enabled, now()));
      return s.families[uid].photoConsent;
    },
    async revokeConsent(uid) {
      const s = await atomic(current => photos.revokePhotoConsent(current, uid, now()));
      return s.families[uid].photoConsent;
    },
    async upload(uid, data) {
      const hostId = requiredId(data?.hostId);
      const opId = requiredId(data?.opId);
      const attemptedAt = now();
      // Count attempts before expensive JPEG decode. Anonymous UID alone must
      // not permit unbounded image processing or billed object writes.
      await atomic(s => {
        photos.checkPhotoAccess(s, uid, hostId);
        rate(s, `photo_upload_${uid}`, attemptedAt, 30, 60 * 60_000);
      });
      const {bytes, sha256} = await sanitizePhotoData(data?.jpegBase64);
      const state = await atomic(s => photos.reservePhoto(s, uid, hostId, opId, newId(), sha256, now()));
      const op = state.photoOps[hostId][opId];
      if (op.status === 'ready') {
        await verifiedBytes(op);
        return publicPhoto(op);
      }

      try {
        await bucket.file(op.objectPath).save(bytes, {
          resumable: false,
          preconditionOpts: {ifGenerationMatch: 0},
          metadata: {contentType: 'image/jpeg', cacheControl: 'private, no-store'},
        });
      } catch (error) {
        // A concurrent retry may have created this exact object. Never overwrite
        // it, and only treat the collision as success when its bytes match.
        if (![409, 412].includes(Number(error?.code))) throw error;
        await verifiedBytes(op);
      }
      // An unpair, pause or revoke between reservation and object save makes
      // this fail. The private object remains inaccessible and cleanup retries
      // its deletion; no "success" response is fabricated.
      const finished = await atomic(s => photos.finalizePhoto(s, uid, hostId, opId, now()));
      return publicPhoto(finished.photoOps[hostId][opId]);
    },
    async get(uid, data) {
      const hostId = requiredId(data?.hostId);
      const mediaId = requiredId(data?.mediaId);
      const attemptedAt = now();
      const authorized = await atomic(s => {
        photos.readPhoto(s, uid, hostId, mediaId, attemptedAt);
        // Conservative upper bound: each response is at most 1 MB. This is
        // only a photo-service guard, not a Firebase billing hard cap.
        rate(s, `photo_download_family_${hostId}`, attemptedAt, FAMILY_DOWNLOAD_LIMIT, THIRTY_DAYS_MS);
        rate(s, `photo_download_${uid}`, attemptedAt, 60, 60 * 60_000);
      });
      const before = photos.readPhoto(authorized, uid, hostId, mediaId, attemptedAt);
      const bytes = await verifiedBytes(before);
      // Re-check after the object read, so a revoke during download does not
      // return it from a stale authorization snapshot.
      const after = photos.readPhoto(await readCore(), uid, hostId, mediaId, now());
      if (after.sha256 !== before.sha256 || after.objectPath !== before.objectPath) {
        throw new Fault('failed-precondition', '照片已更新，請重新載入');
      }
      return {mediaId, jpegBase64: bytes.toString('base64')};
    },
    async list(uid, data) {
      const hostId = requiredId(data?.hostId);
      const attemptedAt = now();
      await atomic(s => {
        photos.checkPhotoAccess(s, uid, hostId);
        rate(s, `photo_list_${uid}`, attemptedAt, 30, 60 * 60_000);
      });
      return photos.listPhotos(await readCore(), uid, hostId, now());
    },
    async cleanup() {
      const allCandidates = photos.photoCleanupCandidates(await readCore(), now());
      const candidates = allCandidates.slice(0, MAX_CLEANUP_BATCH);
      let deleted = 0, failed = 0;
      for (const item of candidates) {
        try {
          try { await bucket.file(item.objectPath).delete(); }
          catch (error) { if (Number(error?.code) !== 404) throw error; }
          await atomic(s => photos.forgetDeletedPhoto(s, item.hostId, item.opId, item.mediaId, now()));
          deleted++;
        } catch { failed++; }
      }
      return {deleted, failed, pending: Math.max(0, allCandidates.length - deleted)};
    },
  };
}

/** Only aggregate counts are logged; a partial delete must fail the schedule. */
export async function runPhotoCleanup(gateway, logSummary) {
  const result = await gateway.cleanup();
  await logSummary(result);
  if (result.failed) throw new Error('Photo cleanup incomplete');
  return result;
}
