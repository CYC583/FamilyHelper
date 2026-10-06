// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import {Fault, member, role} from './state.js';

const PHOTO_TTL_MS = 30 * 24 * 60 * 60_000;
const UPLOAD_LEASE_MS = 10 * 60_000;
const TAIPEI_OFFSET_MS = 8 * 60 * 60_000;
const MAX_TRACKED_OPS = 512;

function fail(code, message) { throw new Fault(code, message); }

function authorize(s, uid, hostId) {
  role(s, hostId, 'host');
  if (uid === hostId) return;
  role(s, uid, 'client');
  member(s, hostId, uid);
  if (s.links?.[uid]?.hostId !== hostId) fail('permission-denied', '已解除家人配對');
}

function activeConsent(s, hostId) {
  const consent = s.families[hostId].photoConsent;
  if (!consent?.enabled) fail('failed-precondition', '長輩尚未同意分享照片或已暫停');
  return consent;
}

/** Cheap authorization gate before JPEG decoding or any Storage operation. */
export function checkPhotoAccess(s, uid, hostId) {
  authorize(s, uid, hostId);
  activeConsent(s, hostId);
}

function validId(value) {
  return typeof value === 'string' && /^[a-zA-Z0-9-]{1,64}$/.test(value);
}

function dayInTaipei(now) {
  return new Date(now + TAIPEI_OFFSET_MS).toISOString().slice(0, 10);
}

/** Host-only consent. The version fences uploads; pause does not delete prior ready media. */
export function setPhotoConsent(s, uid, enabled, now) {
  role(s, uid, 'host');
  if (typeof enabled !== 'boolean' || !Number.isFinite(now)) fail('invalid-argument', '同意設定無效');
  const family = s.families[uid];
  family.photoConsent = {
    enabled,
    version: (family.photoConsent?.version || 0) + 1,
    shareGeneration: family.photoConsent?.shareGeneration || 1,
    updatedAt: now,
  };
  return family.photoConsent;
}

/** Permanent withdrawal: a later grant never resurrects old shared media. */
export function revokePhotoConsent(s, uid, now) {
  role(s, uid, 'host');
  if (!Number.isFinite(now)) fail('invalid-argument', '撤銷時間無效');
  const family = s.families[uid];
  family.photoConsent = {
    enabled: false,
    version: (family.photoConsent?.version || 0) + 1,
    shareGeneration: (family.photoConsent?.shareGeneration || 0) + 1,
    revokedAt: now,
    updatedAt: now,
  };
  return family.photoConsent;
}

/** Runs inside the same /core transaction as pairing/revocation. No object is visible yet. */
export function reservePhoto(s, uid, hostId, opId, mediaId, sha256, now) {
  authorize(s, uid, hostId);
  const consent = activeConsent(s, hostId);
  if (!validId(opId) || !validId(mediaId) || !/^[0-9a-f]{64}$/.test(sha256) || !Number.isFinite(now)) {
    fail('invalid-argument', '照片操作資料無效');
  }
  // /core/families/{hostId} is readable by every bound client. Keep the
  // operation ledger in a sibling that RTDB rules never expose to clients.
  s.photoOps ??= {};
  s.photoOps[hostId] ??= {};
  const ops = s.photoOps[hostId];
  const prior = Object.hasOwn(ops, opId) ? ops[opId] : null;
  if (prior) {
    if (prior.authorId !== uid || prior.sha256 !== sha256) {
      fail('already-exists', '這筆照片操作已使用，請重新拍照');
    }
    if (Number.isFinite(prior.revokedAt) || prior.consentVersion !== consent.version || prior.expiresAt <= now ||
      (prior.status === 'pending' && prior.pendingUntil <= now)) {
      fail('failed-precondition', '照片操作已失效，請重新拍照');
    }
    return prior;
  }
  if (Object.values(ops).some(op => op.mediaId === mediaId)) {
    fail('already-exists', '照片識別碼已使用，請重新上傳');
  }
  if (Object.keys(ops).length >= MAX_TRACKED_OPS) fail('resource-exhausted', '照片紀錄暫時已滿，請稍後再試');
  const day = dayInTaipei(now);
  const count = Object.values(ops).filter(op => op.authorId === uid && op.day === day &&
    (op.status === 'ready' || op.pendingUntil > now)).length;
  if (count >= (uid === hostId ? 1 : 2)) fail('resource-exhausted', '今天的照片張數已達上限');

  const record = {
    mediaId, authorId: uid, sha256, day, status: 'pending',
    consentVersion: consent.version, shareGeneration: consent.shareGeneration, createdAt: now,
    pendingUntil: now + UPLOAD_LEASE_MS, expiresAt: now + PHOTO_TTL_MS,
    objectPath: `care-photos/${hostId}/${mediaId}.jpg`,
  };
  ops[opId] = record;
  return record;
}

/** Publish only after the object exists and after rechecking current consent/member. */
export function finalizePhoto(s, uid, hostId, opId, now) {
  authorize(s, uid, hostId);
  const consent = activeConsent(s, hostId);
  const op = s.photoOps?.[hostId]?.[opId];
  if (!op || op.authorId !== uid || Number.isFinite(op.revokedAt) ||
    op.consentVersion !== consent.version || op.expiresAt <= now) {
    fail('failed-precondition', '照片操作已失效');
  }
  if (op.status === 'ready') return op;
  if (op.status !== 'pending' || op.pendingUntil <= now) fail('failed-precondition', '照片上傳已逾時');
  op.status = 'ready';
  op.readyAt = now;
  return op;
}

/** Metadata only. The caller must fetch bytes from private Storage after this check. */
export function readPhoto(s, uid, hostId, mediaId, now) {
  authorize(s, uid, hostId);
  const consent = activeConsent(s, hostId);
  const op = Object.values(s.photoOps?.[hostId] || {}).find(value => value.mediaId === mediaId);
  if (!op || op.status !== 'ready' || op.shareGeneration !== consent.shareGeneration || op.expiresAt <= now ||
    Number.isFinite(op.revokedAt) ||
    (op.authorId !== hostId && !s.families[hostId].members?.[op.authorId])) {
    fail('not-found', '照片不存在或已到期');
  }
  return op;
}

/** Consent-gated index without paths, hashes, pending records or expired media. */
export function listPhotos(s, uid, hostId, now) {
  authorize(s, uid, hostId);
  const consent = activeConsent(s, hostId);
  const members = s.families[hostId].members || {};
  return Object.values(s.photoOps?.[hostId] || {})
    .filter(op => op.status === 'ready' && op.shareGeneration === consent.shareGeneration &&
      op.expiresAt > now && !Number.isFinite(op.revokedAt) &&
      (op.authorId === hostId || !!members[op.authorId]))
    .sort((a, b) => b.createdAt - a.createdAt)
    .map(op => ({mediaId: op.mediaId, authorId: op.authorId, day: op.day, createdAt: op.createdAt}));
}

function needsPhotoDeletion(op, consent, now) {
  // An in-flight upload can still write after Storage returned 404 to cleanup.
  // Keep its metadata until its upload lease ends; the callable timeout is 30s.
  if (op.status === 'pending' && op.pendingUntil > now) return false;
  return op.expiresAt <= now || (op.status === 'pending' && op.pendingUntil <= now) ||
    Number.isFinite(op.revokedAt) || op.shareGeneration !== consent?.shareGeneration;
}

/** Candidate list only. The scheduler must delete the Storage object first. */
export function photoCleanupCandidates(s, now) {
  const candidates = [];
  for (const [hostId, ops] of Object.entries(s.photoOps || {})) {
    const consent = s.families?.[hostId]?.photoConsent;
    for (const [opId, op] of Object.entries(ops || {})) {
      if (needsPhotoDeletion(op, consent, now)) {
        candidates.push({hostId, opId, mediaId: op.mediaId, objectPath: op.objectPath});
      }
    }
  }
  return candidates;
}

/** Called in a /core transaction only after object deletion succeeded or was 404. */
export function forgetDeletedPhoto(s, hostId, opId, mediaId, now) {
  const op = s.photoOps?.[hostId]?.[opId];
  const consent = s.families?.[hostId]?.photoConsent;
  if (!op || op.mediaId !== mediaId || !needsPhotoDeletion(op, consent, now)) {
    fail('failed-precondition', '照片紀錄已變更，不能刪除');
  }
  delete s.photoOps[hostId][opId];
}
