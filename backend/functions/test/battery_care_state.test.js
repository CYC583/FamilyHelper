// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  setBatteryConsent, applyBatterySample, ackBatteryEvent, setBatteryPreference,
} from '../src/battery_care_state.js';

const T0 = Date.UTC(2026, 9, 2, 10);
const MINUTE = 60_000;
const fail = (fn, code) => assert.throws(fn, error => error.code === code);
const episodeId = 'ep-1234567890abcdef';

function ready() {
  return setBatteryConsent({}, 'grandma', true, T0, {disclosureVersion: 2});
}

function sample(seq, percent, mono, extra = {}) {
  return {
    batteryPercent: percent, charging: false, observedAt: T0 + mono,
    episodeId, sampleSeq: seq, phase: percent <= 30 ? 'low' : 'resolved',
    severity: percent <= 15 ? 'critical' : 'low', consentVersion: 1,
    lowEvidence: percent <= 30 ? {
      bootEpoch: 'boot-a', firstMonotonicMs: 1000, currentMonotonicMs: 1000 + mono,
      firstSampleSeq: 1, currentSampleSeq: seq,
    } : undefined,
    ...extra,
  };
}

test('consent defaults off, validates inputs, increments version and clears private values on revoke', () => {
  fail(() => applyBatterySample({}, sample(1, 30, 0), T0), 'failed-precondition');
  fail(() => setBatteryConsent({}, '', true, T0), 'invalid-argument');
  fail(() => setBatteryConsent({}, 'grandma', 'yes', T0), 'invalid-argument');
  fail(() => setBatteryConsent({}, 'grandma', true, NaN), 'invalid-argument');
  let b = ready();
  assert.deepEqual({enabled: b.consent.enabled, version: b.consent.version}, {enabled: true, version: 1});
  b = applyBatterySample(b, sample(1, 30, 0), T0).battery;
  b = setBatteryConsent(b, 'grandma', false, T0 + 1, {revoke: true});
  assert.equal(b.consent.enabled, false);
  assert.equal(b.consent.status, 'revoked');
  assert.equal(b.consent.version, 2);
  assert.equal(b.latest, undefined);
  assert.deepEqual(b.events, {});
  assert.equal(b.replay.lastSampleSeq, 1);
  fail(() => applyBatterySample(b, sample(2, 30, MINUTE), T0 + MINUTE), 'failed-precondition');
});

test('expanded disclosure is a separate version and old consent cannot authorize a battery sample', () => {
  fail(() => setBatteryConsent({}, 'grandma', true, T0), 'failed-precondition');
  const current = setBatteryConsent({}, 'grandma', true, T0, {disclosureVersion: 2});
  assert.equal(current.consent.version, 1);
  assert.equal(current.consent.disclosureVersion, 2);
  const old = structuredClone(current);
  delete old.consent.disclosureVersion;
  fail(() => applyBatterySample(old, sample(1, 30, 0), T0), 'failed-precondition');
  assert.equal(applyBatterySample(current, sample(1, 30, 0), T0).battery.latest.batteryPercent, 30);
});

test('pause hides values, resume is version fenced, and no old queued sample returns', () => {
  let b = ready();
  b = applyBatterySample(b, sample(1, 30, 0), T0).battery;
  b = setBatteryConsent(b, 'grandma', false, T0 + 1);
  assert.equal(b.consent.status, 'paused');
  assert.equal(b.latest, undefined);
  b = setBatteryConsent(b, 'grandma', true, T0 + 2, {disclosureVersion: 2});
  assert.equal(b.consent.version, 3);
  fail(() => applyBatterySample(b, sample(2, 30, 31 * MINUTE), T0 + 31 * MINUTE), 'failed-precondition');
});

test('still-low pause and reapproval require a new episode but preserve sample sequence', () => {
  let b = applyBatterySample(ready(), sample(1, 30, 0), T0).battery;
  b = setBatteryConsent(b, 'grandma', false, T0 + 1);
  b = setBatteryConsent(b, 'grandma', true, T0 + 2, {disclosureVersion: 2});
  const next = sample(2, 29, 31 * MINUTE, {
    episodeId: 'ep-new-generation', consentVersion: 3,
    lowEvidence: {bootEpoch: 'boot-a', firstMonotonicMs: 1000 + 31 * MINUTE,
      currentMonotonicMs: 1000 + 31 * MINUTE, firstSampleSeq: 2, currentSampleSeq: 2},
  });
  fail(() => applyBatterySample(b, {...next, episodeId}, T0 + 31 * MINUTE), 'failed-precondition');
  const result = applyBatterySample(b, next, T0 + 31 * MINUTE).battery;
  assert.equal(result.replay.lastSampleSeq, 2);
  assert.equal(result.episode.id, 'ep-new-generation');
  assert.equal(result.episode.firstSampleSeq, 2);
});

test('valid 0/15/30/31/100 bounds and bad numeric/type values', () => {
  for (const percent of [0, 15, 30, 31, 100]) {
    const b = ready();
    const result = applyBatterySample(b, sample(1, percent, 0), T0);
    assert.equal(result.battery.latest.batteryPercent, percent);
  }
  for (const percent of [null, NaN, -1, 100.1, 101, '30']) {
    fail(() => applyBatterySample(ready(), sample(1, percent, 0), T0), 'invalid-argument');
  }
  fail(() => applyBatterySample(ready(), sample(1, 30, 0, {charging: 'no'}), T0), 'invalid-argument');
  fail(() => applyBatterySample(ready(), sample(1, 30, 0, {phase: 'critical'}), T0), 'invalid-argument');
  fail(() => applyBatterySample(ready(), sample(1, 30, 0, {severity: 'critical'}), T0), 'invalid-argument');
});

test('first low only writes latest; second measurement after 30 minutes creates one stable event', () => {
  let b = ready();
  let r = applyBatterySample(b, sample(1, 30, 0), T0);
  assert.equal(r.eventId, null);
  assert.deepEqual(r.battery.events, {});
  b = r.battery;
  r = applyBatterySample(b, sample(2, 29, 29 * MINUTE), T0 + 29 * MINUTE);
  assert.equal(r.eventId, null);
  b = r.battery;
  r = applyBatterySample(b, sample(3, 29, 30 * MINUTE), T0 + 30 * MINUTE);
  assert.equal(r.eventId, episodeId);
  assert.equal(r.battery.events[episodeId].createdAt, T0 + 30 * MINUTE);
  assert.equal(r.battery.events[episodeId].lastObservedAt, T0 + 30 * MINUTE);
  assert.equal(r.battery.latest.receivedAt, T0 + 30 * MINUTE);
  assert.equal(Object.keys(r.battery.events).length, 1);
  const duplicate = applyBatterySample(r.battery, sample(3, 29, 30 * MINUTE), T0 + 31 * MINUTE);
  assert.equal(duplicate.changed, false);
  assert.equal(Object.keys(duplicate.battery.events).length, 1);
});

test('critical needs a second <=15 sample after 5 minutes; existing event upgrades only', () => {
  let b = ready();
  b = applyBatterySample(b, sample(1, 30, 0), T0).battery;
  b = applyBatterySample(b, sample(2, 15, 2 * MINUTE), T0 + 2 * MINUTE).battery;
  assert.deepEqual(b.events, {});
  b = applyBatterySample(b, sample(3, 15, 6 * MINUTE), T0 + 6 * MINUTE).battery;
  assert.deepEqual(b.events, {});
  b = applyBatterySample(b, sample(4, 14, 7 * MINUTE), T0 + 7 * MINUTE).battery;
  assert.equal(b.events[episodeId].severity, 'critical');
  assert.equal(Object.keys(b.events).length, 1);
  b = applyBatterySample(b, sample(5, 22, 31 * MINUTE), T0 + 31 * MINUTE).battery;
  assert.equal(b.events[episodeId].severity, 'critical');
  assert.equal(Object.keys(b.events).length, 1);
});

test('charging resolves event; delayed low retry and old episode cannot reopen it', () => {
  let b = ready();
  b = applyBatterySample(b, sample(1, 30, 0), T0).battery;
  b = applyBatterySample(b, sample(2, 30, 31 * MINUTE), T0 + 31 * MINUTE).battery;
  b = applyBatterySample(b, sample(3, 30, 32 * MINUTE, {charging: true, phase: 'resolved'}), T0 + 32 * MINUTE).battery;
  assert.equal(b.events[episodeId].resolvedAt, T0 + 32 * MINUTE);
  assert.equal(b.episode.status, 'resolved');
  fail(() => applyBatterySample(b, sample(2, 30, 31 * MINUTE), T0 + 33 * MINUTE), 'failed-precondition');
  fail(() => applyBatterySample(b, sample(4, 30, 34 * MINUTE), T0 + 34 * MINUTE), 'failed-precondition');
  const next = sample(4, 30, 34 * MINUTE, {
    episodeId: 'ep-next', lowEvidence: {bootEpoch: 'boot-a', firstMonotonicMs: 1000 + 34 * MINUTE,
      currentMonotonicMs: 1000 + 34 * MINUTE, firstSampleSeq: 4, currentSampleSeq: 4},
  });
  b = applyBatterySample(b, next, T0 + 34 * MINUTE).battery;
  assert.equal(b.episode.id, 'ep-next');
  assert.equal(b.events[episodeId].resolvedAt, T0 + 32 * MINUTE);
  fail(() => applyBatterySample(b, sample(5, 30, 35 * MINUTE), T0 + 35 * MINUTE), 'failed-precondition');
});

test('same sequence with different content, regression, wrong version and invalid wall clock reject', () => {
  let b = ready();
  b = applyBatterySample(b, sample(1, 30, 0), T0).battery;
  fail(() => applyBatterySample(b, sample(1, 15, 0), T0 + 1), 'failed-precondition');
  fail(() => applyBatterySample(b, sample(0, 30, 0), T0 + 1), 'invalid-argument');
  fail(() => applyBatterySample(b, sample(2, 30, MINUTE, {consentVersion: 2}), T0 + MINUTE), 'failed-precondition');
  fail(() => applyBatterySample(b, sample(2, 30, MINUTE, {observedAt: T0 + 2 * 24 * 60 * MINUTE}), T0), 'invalid-argument');
  fail(() => applyBatterySample(b, sample(2, 30, MINUTE, {observedAt: null}), T0), 'invalid-argument');
});

test('missing, non-increasing, cross-boot or implausible evidence cannot create event', () => {
  const first = applyBatterySample(ready(), sample(1, 30, 0), T0).battery;
  const later = sample(2, 30, 31 * MINUTE);
  for (const evidence of [
    undefined,
    {...later.lowEvidence, firstSampleSeq: 2},
    {...later.lowEvidence, currentSampleSeq: 1},
    {...later.lowEvidence, bootEpoch: 'boot-b'},
    {...later.lowEvidence, firstMonotonicMs: later.lowEvidence.currentMonotonicMs + 1},
    {...later.lowEvidence, currentMonotonicMs: later.lowEvidence.firstMonotonicMs + 8 * 24 * 60 * MINUTE},
  ]) {
    fail(() => applyBatterySample(first, {...later, lowEvidence: evidence}, T0 + 31 * MINUTE), 'invalid-argument');
  }
});

test('reboot keeps episode and sequence but restarts both monotonic windows', () => {
  let b = ready();
  b = applyBatterySample(b, sample(1, 30, 0), T0).battery;
  const afterBoot = sample(2, 30, MINUTE, {lowEvidence: {
    bootEpoch: 'boot-b', firstMonotonicMs: 500, currentMonotonicMs: 500,
    firstSampleSeq: 2, currentSampleSeq: 2,
  }});
  b = applyBatterySample(b, afterBoot, T0 + MINUTE).battery;
  assert.equal(b.episode.id, episodeId);
  assert.deepEqual(b.events, {});
  const tooSoon = sample(3, 30, 29 * MINUTE, {lowEvidence: {
    bootEpoch: 'boot-b', firstMonotonicMs: 500, currentMonotonicMs: 500 + 28 * MINUTE,
    firstSampleSeq: 2, currentSampleSeq: 3,
  }});
  b = applyBatterySample(b, tooSoon, T0 + 29 * MINUTE).battery;
  assert.deepEqual(b.events, {});
  const later = sample(4, 30, 32 * MINUTE, {lowEvidence: {
    bootEpoch: 'boot-b', firstMonotonicMs: 500, currentMonotonicMs: 500 + 31 * MINUTE,
    firstSampleSeq: 2, currentSampleSeq: 4,
  }});
  b = applyBatterySample(b, later, T0 + 32 * MINUTE).battery;
  assert.equal(b.events[episodeId].severity, 'low');
});

test('offline first upload may prove two same-boot samples, but one sample never proves duration', () => {
  const b = ready();
  const current = sample(9, 28, 31 * MINUTE, {lowEvidence: {
    bootEpoch: 'boot-a', firstMonotonicMs: 1000, currentMonotonicMs: 1000 + 31 * MINUTE,
    firstSampleSeq: 8, currentSampleSeq: 9,
  }});
  const r = applyBatterySample(b, current, T0 + 32 * MINUTE);
  assert.equal(r.eventId, episodeId);
  assert.equal(r.battery.latest.observedAt, current.observedAt);
  assert.equal(r.battery.latest.receivedAt, T0 + 32 * MINUTE);
  fail(() => applyBatterySample(ready(), sample(1, 30, 31 * MINUTE, {
    lowEvidence: {bootEpoch: 'boot-a', firstMonotonicMs: 1000,
      currentMonotonicMs: 1000 + 31 * MINUTE, firstSampleSeq: 1, currentSampleSeq: 1},
  }), T0 + 31 * MINUTE), 'invalid-argument');
  assert.equal(applyBatterySample(ready(), sample(1, 30, 31 * MINUTE, {
    lowEvidence: {bootEpoch: 'boot-a', firstMonotonicMs: 1000 + 31 * MINUTE,
      currentMonotonicMs: 1000 + 31 * MINUTE, firstSampleSeq: 1, currentSampleSeq: 1},
  }), T0 + 31 * MINUTE).eventId, null);
});

test('only an existing event can be acknowledged; each member preference stays separate', () => {
  let b = ready();
  fail(() => ackBatteryEvent(b, episodeId, 'alice', T0), 'not-found');
  b = applyBatterySample(b, sample(1, 30, 0), T0).battery;
  b = applyBatterySample(b, sample(2, 30, 31 * MINUTE), T0 + 31 * MINUTE).battery;
  b = ackBatteryEvent(b, episodeId, 'alice', T0 + 32 * MINUTE);
  assert.equal(b.events[episodeId].acknowledgedAt.alice, T0 + 32 * MINUTE);
  b = ackBatteryEvent(b, episodeId, 'alice', T0 + 33 * MINUTE);
  assert.equal(b.events[episodeId].acknowledgedAt.alice, T0 + 32 * MINUTE);
  b = setBatteryPreference(b, 'alice', {enabled: true, soundEnabled: false,
    quietHours: {start: '22:00', end: '07:00'}, timeZone: 'Asia/Taipei'}, T0);
  assert.equal(b.preferences.alice.soundEnabled, false);
  assert.equal(b.preferences.bob, undefined);
  fail(() => setBatteryPreference(b, 'bob', {enabled: 'yes', soundEnabled: true}, T0), 'invalid-argument');
});

test('retention removing an old event does not recreate it during one long low episode', () => {
  let b = ready();
  b = applyBatterySample(b, sample(1, 30, 0), T0).battery;
  b = applyBatterySample(b, sample(2, 30, 31 * MINUTE), T0 + 31 * MINUTE).battery;
  assert.equal(b.episode.eventCreated, true);
  delete b.events[episodeId]; // The 30-day retention job has pruned this event.
  const later = sample(3, 29, 31 * 24 * 60 * MINUTE, {
    observedAt: T0 + 31 * 24 * 60 * MINUTE,
    lowEvidence: {bootEpoch: 'boot-after-retention', firstMonotonicMs: 1000,
      currentMonotonicMs: 1000, firstSampleSeq: 3, currentSampleSeq: 3},
  });
  b = applyBatterySample(b, later, later.observedAt).battery;
  assert.deepEqual(b.events, {});
});
