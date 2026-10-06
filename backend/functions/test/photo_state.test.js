// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as state from '../src/state.js';
import * as photos from '../src/photo_state.js';

const now = Date.UTC(2026, 9, 2, 10);
const hash = 'a'.repeat(64);
const otherHash = 'b'.repeat(64);
const fails = (fn, code) => assert.throws(fn, error => error.code === code);
function seed() {
  const s = {};
  state.register(s, 'grandma', 'host', '長輩', now);
  for (const uid of ['alice', 'bob', 'outsider']) state.register(s, uid, 'client', uid, now);
  for (const uid of ['alice', 'bob']) {
    state.issueCode(s, 'grandma', uid, now);
    state.bind(s, uid, uid, now + 1);
  }
  return s;
}
const reserve = (s, authorId, opId, at = now) => photos.reservePhoto(s, authorId, 'grandma', opId, opId, hash, at);

test('only grandma can enable photos; no consent means no upload or read', () => {
  const s = seed();
  fails(() => reserve(s, 'alice', 'op-a'), 'failed-precondition');
  fails(() => photos.setPhotoConsent(s, 'alice', true, now), 'permission-denied');
  fails(() => photos.setPhotoConsent(s, 'grandma', 'yes', now), 'invalid-argument');
  assert.equal(photos.setPhotoConsent(s, 'grandma', true, now).version, 1);
  fails(() => reserve(s, 'outsider', 'op-x'), 'permission-denied');
});

test('one grandma and two per-family-member photos per Taipei day', () => {
  const s = seed(); photos.setPhotoConsent(s, 'grandma', true, now);
  reserve(s, 'grandma', 'g1');
  fails(() => reserve(s, 'grandma', 'g2'), 'resource-exhausted');
  reserve(s, 'alice', 'a1'); reserve(s, 'alice', 'a2');
  fails(() => reserve(s, 'alice', 'a3'), 'resource-exhausted');
  reserve(s, 'bob', 'b1');
  reserve(s, 'alice', 'a3', now + 24 * 60 * 60_000);
});

test('same operation is idempotent; changed content or author cannot replay it', () => {
  const s = seed(); photos.setPhotoConsent(s, 'grandma', true, now);
  const first = reserve(s, 'alice', 'a1');
  assert.deepEqual(reserve(s, 'alice', 'a1'), first);
  assert.deepEqual(photos.reservePhoto(s, 'alice', 'grandma', 'a1', 'a-new-random-id', hash, now), first);
  fails(() => photos.reservePhoto(s, 'alice', 'grandma', 'a1', 'a1', otherHash, now), 'already-exists');
  fails(() => reserve(s, 'bob', 'a1'), 'already-exists');
});

test('revoke or pause between reservation and completion prevents publication', () => {
  const s = seed(); photos.setPhotoConsent(s, 'grandma', true, now);
  const a = reserve(s, 'alice', 'a1');
  photos.setPhotoConsent(s, 'grandma', false, now + 1);
  fails(() => photos.finalizePhoto(s, 'alice', 'grandma', 'a1', now + 2), 'failed-precondition');
  photos.setPhotoConsent(s, 'grandma', true, now + 3);
  fails(() => photos.finalizePhoto(s, 'alice', 'grandma', 'a1', now + 4), 'failed-precondition');
  const b = reserve(s, 'bob', 'b1', now + 4);
  state.revoke(s, 'grandma', 'grandma', 'bob', now + 5);
  fails(() => photos.finalizePhoto(s, 'bob', 'grandma', 'b1', now + 6), 'permission-denied');
  assert.equal(a.status, 'pending'); assert.equal(b.status, 'pending');
});

test('only ready, current-consent, unexpired media can be read by current members', () => {
  const s = seed(); photos.setPhotoConsent(s, 'grandma', true, now);
  const op = reserve(s, 'alice', 'a1');
  fails(() => photos.readPhoto(s, 'grandma', 'grandma', op.mediaId, now), 'not-found');
  photos.finalizePhoto(s, 'alice', 'grandma', 'a1', now + 1);
  assert.equal(photos.readPhoto(s, 'bob', 'grandma', op.mediaId, now + 2).mediaId, op.mediaId);
  fails(() => photos.readPhoto(s, 'outsider', 'grandma', op.mediaId, now + 2), 'permission-denied');
  state.revoke(s, 'grandma', 'grandma', 'alice', now + 3);
  fails(() => photos.readPhoto(s, 'alice', 'grandma', op.mediaId, now + 4), 'permission-denied');
  fails(() => photos.readPhoto(s, 'grandma', 'grandma', op.mediaId, now + 4), 'not-found');
});

test('read expires at boundary even if scheduled deletion is late', () => {
  const s = seed(); photos.setPhotoConsent(s, 'grandma', true, now);
  const op = reserve(s, 'grandma', 'g1');
  photos.finalizePhoto(s, 'grandma', 'grandma', 'g1', now + 1);
  assert.equal(photos.readPhoto(s, 'grandma', 'grandma', op.mediaId, op.expiresAt - 1).mediaId, op.mediaId);
  fails(() => photos.readPhoto(s, 'grandma', 'grandma', op.mediaId, op.expiresAt), 'not-found');
});

test('daily limit follows Taipei midnight, not device time or UTC midnight', () => {
  const before = Date.UTC(2026, 9, 2, 15, 59, 59);
  const s = seed(); photos.setPhotoConsent(s, 'grandma', true, before);
  const first = reserve(s, 'grandma', 'g-before', before);
  const second = reserve(s, 'grandma', 'g-after', before + 2_000);
  assert.equal(first.day, '2026-10-02');
  assert.equal(second.day, '2026-10-03');
});

test('renewing consent never resets the same-day photo quota', () => {
  const s = seed(); photos.setPhotoConsent(s, 'grandma', true, now);
  reserve(s, 'grandma', 'g1');
  reserve(s, 'alice', 'a1'); reserve(s, 'alice', 'a2');
  photos.setPhotoConsent(s, 'grandma', true, now + 1);
  fails(() => reserve(s, 'grandma', 'g2', now + 2), 'resource-exhausted');
  fails(() => reserve(s, 'alice', 'a3', now + 2), 'resource-exhausted');
  photos.setPhotoConsent(s, 'grandma', false, now + 3);
  photos.setPhotoConsent(s, 'grandma', true, now + 4);
  fails(() => reserve(s, 'grandma', 'g2', now + 5), 'resource-exhausted');
});

test('different operations cannot reuse the same Storage object ID', () => {
  const s = seed(); photos.setPhotoConsent(s, 'grandma', true, now);
  photos.reservePhoto(s, 'alice', 'grandma', 'a1', 'same-media-id', hash, now);
  fails(() => photos.reservePhoto(s, 'bob', 'grandma', 'b1', 'same-media-id', hash, now), 'already-exists');
});

test('private photo operation ledger is outside the RTDB-readable family subtree', () => {
  const s = seed(); photos.setPhotoConsent(s, 'grandma', true, now);
  reserve(s, 'alice', 'a1');
  assert.equal(s.families.grandma.photoOps, undefined);
  assert.equal(s.photoOps.grandma.a1.authorId, 'alice');
});

test('unpair and re-pair of the same UID cannot resurrect prior photo access', () => {
  const s = seed(); photos.setPhotoConsent(s, 'grandma', true, now);
  const op = reserve(s, 'alice', 'a1');
  photos.finalizePhoto(s, 'alice', 'grandma', 'a1', now + 1);
  state.revoke(s, 'grandma', 'grandma', 'alice', now + 2);
  state.issueCode(s, 'grandma', 'new-code', now + 3);
  state.bind(s, 'alice', 'new-code', now + 4);
  fails(() => photos.readPhoto(s, 'alice', 'grandma', op.mediaId, now + 5), 'not-found');
  fails(() => reserve(s, 'alice', 'a1', now + 5), 'failed-precondition');
  fails(() => photos.finalizePhoto(s, 'alice', 'grandma', 'a1', now + 5), 'failed-precondition');
});

test('pause hides an existing photo, resume restores it but not an in-flight upload', () => {
  const s = seed(); photos.setPhotoConsent(s, 'grandma', true, now);
  const ready = reserve(s, 'alice', 'a1');
  photos.finalizePhoto(s, 'alice', 'grandma', 'a1', now + 1);
  reserve(s, 'alice', 'a2', now + 2);
  photos.setPhotoConsent(s, 'grandma', false, now + 3);
  fails(() => photos.readPhoto(s, 'bob', 'grandma', ready.mediaId, now + 4), 'failed-precondition');
  photos.setPhotoConsent(s, 'grandma', true, now + 5);
  assert.equal(photos.readPhoto(s, 'bob', 'grandma', ready.mediaId, now + 6).mediaId, ready.mediaId);
  fails(() => photos.finalizePhoto(s, 'alice', 'grandma', 'a2', now + 7), 'failed-precondition');
});

test('revoking photos invalidates old ready media even after a new grant', () => {
  const s = seed(); photos.setPhotoConsent(s, 'grandma', true, now);
  const old = reserve(s, 'grandma', 'g1');
  photos.finalizePhoto(s, 'grandma', 'grandma', 'g1', now + 1);
  photos.revokePhotoConsent(s, 'grandma', now + 2);
  photos.setPhotoConsent(s, 'grandma', true, now + 3);
  fails(() => photos.readPhoto(s, 'grandma', 'grandma', old.mediaId, now + 4), 'not-found');
  fails(() => reserve(s, 'grandma', 'g2', now + 4), 'resource-exhausted');
});

test('expired metadata can be forgotten only after selecting its Storage object for deletion', () => {
  const s = seed(); photos.setPhotoConsent(s, 'grandma', true, now);
  s.photoOps = {grandma: {}};
  for (let i = 0; i < 513; i++) {
    s.photoOps.grandma[`old-${i}`] = {
      mediaId: `media-${i}`, authorId: 'grandma', status: 'ready',
      objectPath: `care-photos/grandma/media-${i}.jpg`,
      day: '2026-08-01', shareGeneration: 1, expiresAt: now - 1,
    };
  }
  fails(() => reserve(s, 'grandma', 'new-op'), 'resource-exhausted');
  const candidates = photos.photoCleanupCandidates(s, now);
  assert.equal(candidates.length, 513);
  assert.equal(candidates[0].objectPath, 'care-photos/grandma/media-0.jpg');
  for (const candidate of candidates) {
    photos.forgetDeletedPhoto(s, candidate.hostId, candidate.opId, candidate.mediaId, now);
  }
  assert.equal(Object.keys(s.photoOps.grandma).length, 0);
  reserve(s, 'grandma', 'new-op');
});

test('cleanup refuses a live object or a stale candidate pointing at a replacement', () => {
  const s = seed(); photos.setPhotoConsent(s, 'grandma', true, now);
  reserve(s, 'alice', 'a1');
  fails(() => photos.forgetDeletedPhoto(s, 'grandma', 'a1', 'a1', now + 1), 'failed-precondition');
  fails(() => photos.forgetDeletedPhoto(s, 'grandma', 'a1', 'old-media-id', now + 11 * 60_000), 'failed-precondition');
});

test('pause retains photos while revoke and unpair select them for deletion', () => {
  const s = seed(); photos.setPhotoConsent(s, 'grandma', true, now);
  reserve(s, 'grandma', 'g1'); reserve(s, 'alice', 'a1');
  photos.finalizePhoto(s, 'grandma', 'grandma', 'g1', now + 1);
  photos.finalizePhoto(s, 'alice', 'grandma', 'a1', now + 1);
  photos.setPhotoConsent(s, 'grandma', false, now + 2);
  assert.deepEqual(photos.photoCleanupCandidates(s, now + 3), []);
  state.revoke(s, 'grandma', 'grandma', 'alice', now + 4);
  assert.deepEqual(photos.photoCleanupCandidates(s, now + 5).map(item => item.opId), ['a1']);
  photos.revokePhotoConsent(s, 'grandma', now + 6);
  assert.deepEqual(photos.photoCleanupCandidates(s, now + 7).map(item => item.opId), ['g1', 'a1']);
});
