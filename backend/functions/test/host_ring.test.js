// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as m from '../src/state.js';

const T = 5_000_000;
function family() {
  const s = {};
  m.register(s, 'grandma', 'host', '長輩', T);
  for (const uid of ['alice', 'bob', 'eve']) m.register(s, uid, 'client', uid, T);
  for (const uid of ['alice', 'bob']) { m.issueCode(s, 'grandma', `h-${uid}`, T); m.bind(s, uid, `h-${uid}`, T); }
  return s;
}

test('grandma rings everyone; the first member to answer gets the session', () => {
  const s = family();
  assert.equal(m.ringFamily(s, 'grandma', 'c1', 'call', T), true);
  assert.equal(s.sessions.c1.status, 'ringing');
  assert.equal(s.sessions.c1.shareScreen, true);
  assert.throws(() => m.answerRing(s, 'eve', 'c1', T + 1), {code: 'permission-denied'});
  const v = m.answerRing(s, 'bob', 'c1', T + 2);
  assert.equal(v.clientId, 'bob');
  assert.equal(v.status, 'accepted');
  assert.throws(() => m.answerRing(s, 'alice', 'c1', T + 3), {code: 'failed-precondition'});
  // The accepted session is a normal session: heartbeat works for both sides.
  m.heartbeat(s, 'bob', 'c1', T + 4);
  m.heartbeat(s, 'grandma', 'c1', T + 5);
});

test('answering marks the alert so other family phones can show who answered', () => {
  const s = family();
  s.families.grandma.alerts = {a1: {type: 'sos', createdAt: T}};
  m.ringFamily(s, 'grandma', 'c9', 'sos', T, 'a1');
  m.answerRing(s, 'alice', 'c9', T + 1);
  assert.deepEqual(s.families.grandma.alerts.a1.answeredBy, {uid: 'alice', name: 'alice', at: T + 1});
});

test('SOS rings without screen sharing; ring expires; a busy session blocks a new ring', () => {
  const s = family();
  assert.equal(m.ringFamily(s, 'grandma', 's1', 'sos', T), true);
  assert.equal(s.sessions.s1.shareScreen, false);
  assert.equal(m.ringFamily(s, 'grandma', 's2', 'call', T + 1), false, 'one session at a time');
  assert.throws(() => m.answerRing(s, 'alice', 's1', T + m.RING_TTL), {code: 'failed-precondition'});
  assert.equal(m.ringFamily(s, 'grandma', 's3', 'call', T + m.RING_TTL + 1), true, 'expired ring frees the slot');
  assert.throws(() => m.requestSession(s, 'alice', 'grandma', 'r1', T + m.RING_TTL + 2), {code: 'already-exists'});
});

test('no ring without family members, and only the host can ring', () => {
  const s = {};
  m.register(s, 'grandma', 'host', '長輩', T);
  assert.equal(m.ringFamily(s, 'grandma', 'x', 'sos', T), false);
  const f = family();
  assert.throws(() => m.ringFamily(f, 'alice', 'x', 'call', T), {code: 'permission-denied'});
});
