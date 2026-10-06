// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as coreModel from '../src/state.js';
import {setBatteryConsent as consentTransition} from '../src/battery_care_state.js';
import {createBatteryGateway} from '../src/battery_care_gateway.js';

const T0 = Date.UTC(2026, 9, 2, 10);
const MINUTE = 60_000;
const EVENT_ID = 'battery-episode-1';
const fails = (action, code) => assert.rejects(action, error => error.code === code);

function fixture({members = ['alice', 'bob', 'carol', 'dave'], send = () => 'accepted'} = {}) {
  const root = {core: {}, care: {grandma: {battery: {}}}};
  coreModel.register(root.core, 'grandma', 'host', '長輩', T0);
  for (const uid of [...members, 'outsider']) {
    coreModel.register(root.core, uid, 'client', uid, T0);
    if (members.includes(uid)) {
      coreModel.issueCode(root.core, 'grandma', `hash-${uid}`, T0);
      coreModel.bind(root.core, uid, `hash-${uid}`, T0 + 1);
    }
  }
  const calls = [];
  let now = T0;
  const gateway = createBatteryGateway({
    readCore: async () => structuredClone(root.core),
    readBattery: async hostId => structuredClone(root.care[hostId]?.battery || {}),
    transactBattery: async (hostId, update) => {
      const current = structuredClone(root.care[hostId]?.battery || {});
      const next = update(current);
      root.care[hostId] ??= {};
      root.care[hostId].battery = next;
      return structuredClone(next);
    },
    transactRoot: async update => {
      const next = structuredClone(root);
      update(next);
      Object.assign(root, next);
      return structuredClone(root);
    },
    readToken: async uid => ({token: `token-${uid}`}),
    sendOne: async payload => { calls.push(payload); return send(payload); },
    clock: () => now,
  });
  return {root, gateway, calls, setNow: value => { now = value; }};
}

function sample(seq, percent, elapsed) {
  return {
    batteryPercent: percent, charging: false, observedAt: T0 + elapsed,
    episodeId: EVENT_ID, sampleSeq: seq, phase: 'low',
    severity: percent <= 15 ? 'critical' : 'low',
    lowEvidence: {bootEpoch: 'boot-1', firstMonotonicMs: 1000,
      currentMonotonicMs: 1000 + elapsed, firstSampleSeq: 1, currentSampleSeq: seq},
  };
}

test('host-only consent and report are version fenced; no event on first sample', async () => {
  const f = fixture();
  await fails(() => f.gateway.reportBatterySample('grandma', {sample: sample(1, 30, 0), consentVersion: 1}), 'failed-precondition');
  await fails(() => f.gateway.setBatteryConsent('alice', {enabled: true, expectedVersion: 0}), 'permission-denied');
  await fails(() => f.gateway.setBatteryConsent('grandma', {enabled: true, expectedVersion: 0}), 'failed-precondition');
  const consent = await f.gateway.setBatteryConsent('grandma',
    {enabled: true, expectedVersion: 0, disclosureVersion: 2});
  assert.equal(consent.version, 1);
  await fails(() => f.gateway.setBatteryConsent('grandma', {enabled: false, expectedVersion: 0}), 'failed-precondition');
  await fails(() => f.gateway.reportBatterySample('alice', {sample: sample(1, 30, 0), consentVersion: 1}), 'permission-denied');
  const first = await f.gateway.reportBatterySample('grandma', {sample: sample(1, 30, 0), consentVersion: 1});
  assert.equal(first.eventId, null);
  assert.equal(first.syncedAt, T0);
  assert.equal(f.calls.length, 0);
  f.setNow(T0 + 31 * MINUTE);
  await f.gateway.setBatteryConsent('grandma', {enabled: false, expectedVersion: 1, revoke: true});
  await fails(() => f.gateway.reportBatterySample('grandma', {sample: sample(2, 30, 31 * MINUTE), consentVersion: 1}), 'failed-precondition');
  assert.deepEqual(f.root.care.grandma.battery.events, {});
});

test('four members have independent accepted/failed/unknown results and bounded retry', async () => {
  const results = {alice: 'accepted', bob: 'failed', carol: 'unknown', dave: 'failed'};
  const f = fixture({send: ({uid}) => results[uid]});
  await f.gateway.setBatteryConsent('grandma', {enabled: true, expectedVersion: 0, disclosureVersion: 2});
  await f.gateway.reportBatterySample('grandma', {sample: sample(1, 30, 0), consentVersion: 1});
  f.setNow(T0 + 31 * MINUTE);
  const result = await f.gateway.reportBatterySample('grandma', {sample: sample(2, 30, 31 * MINUTE), consentVersion: 1});
  assert.equal(result.eventId, EVENT_ID);
  assert.equal(f.calls.length, 4);
  assert.deepEqual(Object.fromEntries(Object.entries(f.root.care.grandma.battery.pushOps[EVENT_ID])
    .map(([uid, op]) => [uid, op.status])), results);
  assert.deepEqual(f.calls[0].data, {type: 'careBattery', hostId: 'grandma', eventId: EVENT_ID});
  assert.equal(JSON.stringify(f.calls).includes('batteryPercent'), false);
  assert.equal(JSON.stringify(f.calls).includes('長輩'), false);
  await f.gateway.reportBatterySample('grandma', {sample: sample(2, 30, 31 * MINUTE), consentVersion: 1});
  assert.equal(f.calls.length, 4, 'same sample must not consume the one allowed retry');
  results.bob = 'accepted';
  results.dave = 'accepted';
  f.setNow(T0 + 32 * MINUTE);
  await f.gateway.reportBatterySample('grandma', {sample: sample(3, 29, 32 * MINUTE), consentVersion: 1});
  assert.deepEqual(f.calls.slice(4).map(call => call.uid).sort(), ['bob', 'dave']);
  f.setNow(T0 + 33 * MINUTE);
  await f.gateway.reportBatterySample('grandma', {sample: sample(4, 29, 33 * MINUTE), consentVersion: 1});
  assert.equal(f.calls.length, 6);
  assert.equal(f.root.care.grandma.battery.pushOps[EVENT_ID].bob.attempts, 2);
  assert.equal(f.root.care.grandma.battery.pushOps[EVENT_ID].carol.attempts, 1);
});

test('unpair after reservation but before send suppresses a new push', async () => {
  const f = fixture({members: ['alice']});
  await f.gateway.setBatteryConsent('grandma', {enabled: true, expectedVersion: 0, disclosureVersion: 2});
  await f.gateway.reportBatterySample('grandma', {sample: sample(1, 30, 0), consentVersion: 1});
  // The token read happens after reservation and before the final membership read.
  f.gateway.deps.readToken = async uid => {
    coreModel.revoke(f.root.core, 'grandma', 'grandma', uid, T0 + 30 * MINUTE);
    return {token: `token-${uid}`};
  };
  f.setNow(T0 + 31 * MINUTE);
  await f.gateway.reportBatterySample('grandma', {sample: sample(2, 30, 31 * MINUTE), consentVersion: 1});
  assert.equal(f.calls.length, 0);
  assert.equal(f.root.care.grandma.battery.pushOps[EVENT_ID].alice.status, 'unknown');
  await fails(() => f.gateway.ackBatteryEvent('alice', {hostId: 'grandma', eventId: EVENT_ID}), 'permission-denied');
});

test('host revocation after reservation but before send suppresses a new push', async () => {
  const f = fixture({members: ['alice']});
  await f.gateway.setBatteryConsent('grandma', {enabled: true, expectedVersion: 0, disclosureVersion: 2});
  await f.gateway.reportBatterySample('grandma', {sample: sample(1, 30, 0), consentVersion: 1});
  f.gateway.deps.readToken = async uid => {
    f.root.care.grandma.battery = consentTransition(
      f.root.care.grandma.battery, 'grandma', false, T0 + 31 * MINUTE, {revoke: true});
    return {token: `token-${uid}`};
  };
  f.setNow(T0 + 31 * MINUTE);
  await f.gateway.reportBatterySample('grandma', {sample: sample(2, 30, 31 * MINUTE), consentVersion: 1});
  assert.equal(f.calls.length, 0);
});

test('disclosure becomes obsolete after reservation and before token read: no family push', async () => {
  const f = fixture({members: ['alice']});
  await f.gateway.setBatteryConsent('grandma',
    {enabled: true, expectedVersion: 0, disclosureVersion: 2});
  await f.gateway.reportBatterySample('grandma', {sample: sample(1, 30, 0), consentVersion: 1});
  f.gateway.deps.readToken = async uid => {
    f.root.care.grandma.battery.consent.disclosureVersion = 1;
    return {token: `token-${uid}`};
  };
  f.setNow(T0 + 31 * MINUTE);
  await f.gateway.reportBatterySample('grandma',
    {sample: sample(2, 30, 31 * MINUTE), consentVersion: 1});
  assert.equal(f.calls.length, 0);
});

test('only current family members can ack and set their own sound/quiet preference', async () => {
  const f = fixture({members: ['alice', 'bob']});
  await f.gateway.setBatteryConsent('grandma', {enabled: true, expectedVersion: 0, disclosureVersion: 2});
  await f.gateway.reportBatterySample('grandma', {sample: sample(1, 30, 0), consentVersion: 1});
  f.setNow(T0 + 31 * MINUTE);
  await f.gateway.reportBatterySample('grandma', {sample: sample(2, 30, 31 * MINUTE), consentVersion: 1});
  await fails(() => f.gateway.ackBatteryEvent('outsider', {hostId: 'grandma', eventId: EVENT_ID}), 'permission-denied');
  await f.gateway.ackBatteryEvent('alice', {hostId: 'grandma', eventId: EVENT_ID});
  assert.equal(f.root.care.grandma.battery.events[EVENT_ID].acknowledgedAt.alice, T0 + 31 * MINUTE);
  assert.equal(f.root.care.grandma.battery.events[EVENT_ID].acknowledgedAt.bob, undefined);
  await f.gateway.setBatteryNotificationPreference('bob', {
    hostId: 'grandma', enabled: true, soundEnabled: true,
    quietHours: {start: '22:00', end: '07:00'}, timeZone: 'Asia/Taipei',
  });
  assert.equal(f.root.care.grandma.battery.preferences.bob.soundEnabled, true);
  await fails(() => f.gateway.setBatteryNotificationPreference('outsider', {
    hostId: 'grandma', enabled: true, soundEnabled: true,
  }), 'permission-denied');
  coreModel.revoke(f.root.core, 'grandma', 'grandma', 'bob', T0 + 32 * MINUTE);
  await fails(() => f.gateway.setBatteryNotificationPreference('bob', {
    hostId: 'grandma', enabled: true, soundEnabled: true,
  }), 'permission-denied');
});

test('missing token is an explicit failed attempt; disabled member receives no attempt', async () => {
  const f = fixture({members: ['alice', 'bob']});
  await f.gateway.setBatteryNotificationPreference('alice', {
    hostId: 'grandma', enabled: false, soundEnabled: false,
  });
  f.gateway.deps.readToken = async uid => uid === 'bob' ? null : {token: `token-${uid}`};
  await f.gateway.setBatteryConsent('grandma', {enabled: true, expectedVersion: 0, disclosureVersion: 2});
  await f.gateway.reportBatterySample('grandma', {sample: sample(1, 30, 0), consentVersion: 1});
  f.setNow(T0 + 31 * MINUTE);
  const result = await f.gateway.reportBatterySample('grandma', {
    sample: sample(2, 30, 31 * MINUTE), consentVersion: 1,
  });
  assert.equal(result.pushAttempt.failed, 1);
  assert.equal(f.calls.length, 0);
  assert.equal(f.root.care.grandma.battery.pushOps[EVENT_ID].alice, undefined);
  assert.equal(f.root.care.grandma.battery.pushOps[EVENT_ID].bob.status, 'failed');
  f.gateway.deps.readToken = async uid => ({token: `token-${uid}`});
  f.setNow(T0 + 32 * MINUTE);
  await f.gateway.reportBatterySample('grandma', {sample: sample(3, 29, 32 * MINUTE), consentVersion: 1});
  assert.deepEqual(f.calls.map(call => call.uid), ['bob']);
});

test('quiet hours silence only that member while another member may choose sound', async () => {
  const f = fixture({members: ['alice', 'bob']});
  await f.gateway.setBatteryNotificationPreference('alice', {
    hostId: 'grandma', enabled: true, soundEnabled: true,
    quietHours: {start: '18:00', end: '19:00'}, timeZone: 'Asia/Taipei',
  });
  await f.gateway.setBatteryNotificationPreference('bob', {
    hostId: 'grandma', enabled: true, soundEnabled: true, timeZone: 'Asia/Taipei',
  });
  await f.gateway.setBatteryConsent('grandma', {enabled: true, expectedVersion: 0, disclosureVersion: 2});
  await f.gateway.reportBatterySample('grandma', {sample: sample(1, 30, 0), consentVersion: 1});
  f.setNow(T0 + 31 * MINUTE); // 18:31 in Taipei.
  await f.gateway.reportBatterySample('grandma', {sample: sample(2, 30, 31 * MINUTE), consentVersion: 1});
  assert.equal(f.calls.find(call => call.uid === 'alice').channelId, 'care_battery_silent');
  assert.equal(f.calls.find(call => call.uid === 'bob').channelId, 'care_battery_sound');
});

test('overnight quiet hours handle both sides of Taipei midnight', async () => {
  for (const [offsetHours, expected] of [[5, 'care_battery_silent'], [14, 'care_battery_sound']]) {
    const f = fixture({members: ['alice']});
    await f.gateway.setBatteryNotificationPreference('alice', {
      hostId: 'grandma', enabled: true, soundEnabled: true,
      quietHours: {start: '22:00', end: '07:00'}, timeZone: 'Asia/Taipei',
    });
  await f.gateway.setBatteryConsent('grandma', {enabled: true, expectedVersion: 0, disclosureVersion: 2});
    await f.gateway.reportBatterySample('grandma', {sample: sample(1, 30, 0), consentVersion: 1});
    f.setNow(T0 + offsetHours * 60 * MINUTE);
    await f.gateway.reportBatterySample('grandma', {
      sample: sample(2, 30, 31 * MINUTE), consentVersion: 1,
    });
    assert.equal(f.calls[0].channelId, expected);
  }
});

test('charging resolves event and an older low retry cannot trigger another family push', async () => {
  const f = fixture({members: ['alice']});
  await f.gateway.setBatteryConsent('grandma', {enabled: true, expectedVersion: 0, disclosureVersion: 2});
  await f.gateway.reportBatterySample('grandma', {sample: sample(1, 30, 0), consentVersion: 1});
  f.setNow(T0 + 31 * MINUTE);
  await f.gateway.reportBatterySample('grandma', {sample: sample(2, 30, 31 * MINUTE), consentVersion: 1});
  assert.equal(f.calls.length, 1);
  f.setNow(T0 + 32 * MINUTE);
  const charging = {...sample(3, 30, 32 * MINUTE), charging: true, phase: 'resolved'};
  const resolved = await f.gateway.reportBatterySample('grandma', {sample: charging, consentVersion: 1});
  assert.equal(resolved.eventId, null);
  await fails(() => f.gateway.reportBatterySample('grandma', {
    sample: sample(2, 30, 31 * MINUTE), consentVersion: 1,
  }), 'failed-precondition');
  assert.equal(f.calls.length, 1);
  assert.ok(f.root.care.grandma.battery.events[EVENT_ID].resolvedAt);
});
