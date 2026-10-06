// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';
import {pruneBatteryCare, needsBatteryCleanup, runBatteryCleanup} from '../src/battery_care_cleanup.js';

const DAY = 24 * 60 * 60_000;
const NOW = Date.UTC(2026, 9, 2, 10);

test('29-day event remains; 30-day boundary and 31-day unresolved event expire', () => {
  const battery = {
    consent: {enabled: true, version: 1},
    latest: {batteryPercent: 22, receivedAt: NOW},
    episode: {id: 'unresolved', status: 'active', eventCreated: true},
    events: {
      recent: {createdAt: NOW - 29 * DAY, severity: 'low'},
      boundary: {createdAt: NOW - 30 * DAY, severity: 'low'},
      unresolved: {createdAt: NOW - 31 * DAY, severity: 'critical'},
    },
    pushOps: {
      recent: {alice: {status: 'accepted', attemptedAt: NOW - 29 * DAY}},
      boundary: {alice: {status: 'unknown', attemptedAt: NOW - 30 * DAY}},
      unresolved: {bob: {status: 'failed', attemptedAt: NOW - 31 * DAY}},
    },
  };
  assert.equal(needsBatteryCleanup(battery, NOW), true);
  const result = pruneBatteryCare(battery, NOW);
  assert.deepEqual(Object.keys(result.battery.events), ['recent']);
  assert.deepEqual(Object.keys(result.battery.pushOps), ['recent']);
  assert.equal(result.removedEvents, 2);
  assert.equal(result.removedAttempts, 2);
  assert.equal(result.battery.latest.batteryPercent, 22);
  assert.equal(result.battery.episode.eventCreated, true);
  assert.equal(Object.keys(battery.events).length, 3, 'pure cleanup must not mutate its argument');
});

test('orphan/expired private attempts are removed without deleting a live event', () => {
  const battery = {events: {live: {createdAt: NOW - DAY}}, pushOps: {
    live: {alice: {attemptedAt: NOW - 31 * DAY}, bob: {attemptedAt: NOW - DAY}},
    orphan: {alice: {attemptedAt: NOW - DAY}},
  }};
  const result = pruneBatteryCare(battery, NOW);
  assert.deepEqual(Object.keys(result.battery.events), ['live']);
  assert.deepEqual(Object.keys(result.battery.pushOps.live), ['bob']);
  assert.equal(result.battery.pushOps.orphan, undefined);
  assert.equal(result.removedAttempts, 2);
  assert.equal(needsBatteryCleanup(result.battery, NOW), false);
});

test('invalid timestamps cannot keep records indefinitely', () => {
  const result = pruneBatteryCare({events: {broken: {createdAt: null}}, pushOps: {
    broken: {alice: {attemptedAt: NaN}},
  }}, NOW);
  assert.deepEqual(result.battery.events, {});
  assert.deepEqual(result.battery.pushOps, {});
});

test('scheduled battery cleanup runs independently for registered hosts without Storage', async () => {
  const stored = {
    grandma: {events: {old: {createdAt: NOW - 31 * DAY}},
      pushOps: {old: {alice: {attemptedAt: NOW - 31 * DAY}}}},
    second: {events: {recent: {createdAt: NOW - DAY}}},
  };
  const visited = [];
  const summary = await runBatteryCleanup({
    hostIds: ['grandma', 'second'], now: NOW,
    readBattery: async hostId => structuredClone(stored[hostId]),
    transactBattery: async (hostId, update) => {
      visited.push(hostId);
      stored[hostId] = update(structuredClone(stored[hostId]));
      return structuredClone(stored[hostId]);
    },
  });
  assert.deepEqual(visited, ['grandma']);
  assert.deepEqual(summary, {hostsChecked: 2, hostsChanged: 1,
    removedEvents: 1, removedAttempts: 1});
  assert.deepEqual(stored.grandma.events, {});
  assert.ok(stored.second.events.recent);
});
