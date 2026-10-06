// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as m from '../src/state.js';
import {transact} from '../src/atomic.js';
const now = 1_000_000;
function seed() {
  const s = {};
  m.register(s, 'grandma', 'host', '長輩', now);
  for (const uid of ['alice', 'bob', 'carol', 'dave', 'frank', 'gina', 'eve']) m.register(s, uid, 'client', uid, now);
  return s;
}
function bind(s, uid, hash = uid) { m.issueCode(s, 'grandma', hash, now); m.bind(s, uid, hash, now + 1); }
const fails = (fn, code) => assert.throws(fn, e => e.code === code);
test('one-time code cannot bind a second device', () => {
  const s = seed(); bind(s, 'alice', 'hashed');
  fails(() => m.bind(s, 'bob', 'hashed', now + 2), 'not-found');
});
test('expired code and replaced code are rejected', () => {
  const s = seed(); m.issueCode(s, 'grandma', 'first', now); m.issueCode(s, 'grandma', 'second', now);
  fails(() => m.bind(s, 'alice', 'first', now), 'not-found');
  fails(() => m.bind(s, 'alice', 'second', now + m.PAIR_TTL), 'not-found');
});
test('up to six clients fit; seventh cannot issue or use a valid code', () => {
  const s = seed();
  for (const uid of ['alice', 'bob', 'carol', 'dave', 'frank', 'gina']) bind(s, uid);
  assert.deepEqual(Object.keys(s.families.grandma.members), ['alice', 'bob', 'carol', 'dave', 'frank', 'gina']);
  fails(() => m.issueCode(s, 'grandma', 'seventh', now), 'resource-exhausted');
  s.pairCodes.stale = {hostId: 'grandma', expiresAt: now + 100};
  const members = structuredClone(s.families.grandma.members);
  const links = structuredClone(s.links);
  fails(() => m.bind(s, 'eve', 'stale', now), 'resource-exhausted');
  assert.deepEqual(s.families.grandma.members, members);
  assert.deepEqual(s.links, links);
});
test('revoking one of six clients frees a slot without changing the single assistance lock', () => {
  const s = seed();
  for (const uid of ['alice', 'bob', 'carol', 'dave', 'frank', 'gina']) bind(s, uid);
  m.revoke(s, 'grandma', 'grandma', 'bob', now + 2);
  assert.equal(s.links.bob, undefined);
  bind(s, 'eve', 'replacement');
  assert.deepEqual(Object.keys(s.families.grandma.members), ['alice', 'carol', 'dave', 'frank', 'gina', 'eve']);
  m.requestSession(s, 'alice', 'grandma', 'one', now + 3);
  fails(() => m.requestSession(s, 'dave', 'grandma', 'two', now + 3), 'already-exists');
  assert.equal(s.families.grandma.activeSessionId, 'one');
});
test('a client cannot change its registered role', () => {
  const s = seed(); fails(() => m.register(s, 'alice', 'host', 'fake', now), 'permission-denied');
});
test('registration permits only one host and caps anonymous devices', () => {
  const s = seed();
  fails(() => m.register(s, 'other-host', 'host', '長輩', now), 'failed-precondition');
  while (Object.keys(s.devices).length < m.MAX_REGISTERED_DEVICES) {
    m.register(s, `extra-${Object.keys(s.devices).length}`, 'client', '家人', now);
  }
  fails(() => m.register(s, 'overflow', 'client', '家人', now), 'resource-exhausted');
  m.register(s, 'alice', 'client', 'Alice', now + 1);
  assert.equal(Object.keys(s.devices).length, 16);
});
test('SOS push payload never exposes location outside the protected database', () => {
  const payload = m.alertPush('sos', 'grandma', 'alert-1');
  assert.deepEqual(payload.data, {type: 'sos', hostId: 'grandma', alertId: 'alert-1'});
  assert.doesNotMatch(JSON.stringify(payload), /lat|lng|location|座標|位置/);
});
test('cleanup skips empty and live state, but detects expired records', () => {
  assert.equal(m.needsCleanup({}, now), false);
  const s = seed(); bind(s, 'alice');
  m.requestSession(s, 'alice', 'grandma', 'one', now);
  assert.equal(m.needsCleanup(s, now + 1), false);
  assert.equal(m.needsCleanup(s, now + m.REQUEST_TTL), true);
  delete s.sessions.one;
  delete s.families.grandma.activeSessionId;
  assert.equal(m.needsCleanup(s, now + 1), false);
  s.rates = {old: {count: 1, until: now}};
  assert.equal(m.needsCleanup(s, now), true);
});
test('unbound device cannot request assistance', () => {
  fails(() => m.requestSession(seed(), 'eve', 'grandma', 'x', now), 'permission-denied');
});
test('pending request reserves the single slot against another client', () => {
  const s = seed(); bind(s, 'alice'); bind(s, 'bob');
  m.requestSession(s, 'alice', 'grandma', 'one', now);
  fails(() => m.requestSession(s, 'bob', 'grandma', 'two', now), 'already-exists');
  assert.equal(s.families.grandma.activeSessionId, 'one');
});
test('client cannot consent for the host', () => {
  const s = seed(); bind(s, 'alice'); m.requestSession(s, 'alice', 'grandma', 'one', now);
  fails(() => m.accept(s, 'alice', 'one', now), 'failed-precondition');
  assert.equal(s.sessions.one.status, 'pending');
});
test('reject releases lock and prevents late acceptance', () => {
  const s = seed(); bind(s, 'alice'); m.requestSession(s, 'alice', 'grandma', 'one', now);
  m.finish(s, 'grandma', 'one', 'rejected', now + 1);
  assert.equal(s.families.grandma.activeSessionId, undefined);
  fails(() => m.accept(s, 'grandma', 'one', now + 2), 'failed-precondition');
});
test('expired pending session replaced; late host acceptance cannot steal lock', () => {
  const s = seed(); bind(s, 'alice'); bind(s, 'bob');
  m.requestSession(s, 'alice', 'grandma', 'one', now);
  m.requestSession(s, 'bob', 'grandma', 'two', now + m.REQUEST_TTL + 1);
  fails(() => m.accept(s, 'grandma', 'one', now + m.REQUEST_TTL + 2), 'failed-precondition');
  assert.equal(s.families.grandma.activeSessionId, 'two');
});
test('one participant cannot keep an abandoned session alive alone', () => {
  const s = seed(); bind(s, 'alice'); m.requestSession(s, 'alice', 'grandma', 'one', now); m.accept(s, 'grandma', 'one', now);
  m.heartbeat(s, 'alice', 'one', now + 20_000);
  assert.equal(s.sessions.one.leaseUntil, now + m.LEASE_MS);
  fails(() => m.heartbeat(s, 'alice', 'one', now + m.LEASE_MS + 1), 'failed-precondition');
});
test('both heartbeats renew lease but never extend maximum consent duration', () => {
  const s = seed(); bind(s, 'alice'); m.requestSession(s, 'alice', 'grandma', 'one', now); m.accept(s, 'grandma', 'one', now);
  m.heartbeat(s, 'alice', 'one', now + 10_000); m.heartbeat(s, 'grandma', 'one', now + 11_000);
  assert.equal(s.sessions.one.leaseUntil, now + 10_000 + m.LEASE_MS);
  assert.equal(s.sessions.one.expiresAt, now + m.SESSION_TTL);
});
test('revocation immediately ends active session and removes both memberships', () => {
  const s = seed(); bind(s, 'alice'); m.requestSession(s, 'alice', 'grandma', 'one', now); m.accept(s, 'grandma', 'one', now);
  m.revoke(s, 'grandma', 'grandma', 'alice', now + 2);
  assert.equal(s.sessions.one.status, 'ended'); assert.equal(s.links.alice, undefined);
  fails(() => m.getSession(s, 'alice', 'one'), 'permission-denied');
});
test('client cannot unpair a sibling', () => {
  const s = seed(); bind(s, 'alice'); bind(s, 'bob');
  fails(() => m.revoke(s, 'alice', 'grandma', 'bob', now), 'permission-denied');
});
test('finishing old session cannot clear the current session lock', () => {
  const s = seed(); bind(s, 'alice'); bind(s, 'bob');
  m.requestSession(s, 'alice', 'grandma', 'one', now); m.finish(s, 'alice', 'one', 'ended', now);
  m.requestSession(s, 'bob', 'grandma', 'two', now); m.finish(s, 'alice', 'one', 'ended', now);
  assert.equal(s.families.grandma.activeSessionId, 'two');
});
test('rate limit rejects sixth attempt then expires', () => {
  const s = {}; for (let i = 0; i < 5; i++) m.rate(s, 'user', now, 5, 100);
  fails(() => m.rate(s, 'user', now, 5, 100), 'resource-exhausted');
  m.rate(s, 'user', now + 100, 5, 100); assert.equal(s.rates.user.count, 1);
});
test('health thresholds have no invented medical defaults', () => {
  assert.deepEqual(m.healthBreaches({heart: {value: 180, time: now}}, {}, now), []);
});
test('health alerts reject stale and future measurements', () => {
  assert.deepEqual(m.healthBreaches({heart: {value: 180, time: now - 900_001}}, {heartHigh: 150}, now), []);
  assert.deepEqual(m.healthBreaches({oxygen: {value: 80, time: now + 120_000}}, {oxygenLow: 90}, now), []);
});
test('new measurements honor user-supplied thresholds', () => {
  assert.deepEqual(m.healthBreaches({heart: {value: 180, time: now}, oxygen: {value: 88, time: now}}, {heartHigh: 150, oxygenLow: 90}, now), ['heart', 'oxygen']);
});
test('cold-start provisional null gets retried instead of aborting authorization', async () => {
  const state = seed(); bind(state, 'alice');
  const fake = {transaction: async fn => {
    assert.deepEqual(fn(null), {});
    const updated = fn(structuredClone(state));
    return {committed: true, snapshot: {val: () => updated}};
  }};
  const result = await transact(fake, s => m.requestSession(s, 'alice', 'grandma', 'one', now));
  assert.equal(result.sessions.one.status, 'pending');
});
test('genuinely empty database still rejects unauthorized operation', async () => {
  const fake = {transaction: async fn => ({committed: true, snapshot: {val: () => fn(null)}})};
  // Real SDK calls the update before resolving the transaction result.
  fake.transaction = async fn => { const value = fn(null); return {committed: true, snapshot: {val: () => value}}; };
  await assert.rejects(transact(fake, s => m.role(s, 'eve', 'host')), e => e.code === 'permission-denied');
});
