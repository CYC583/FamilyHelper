// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';
import {reportReminderStatus} from '../src/reminder_status_state.js';

const NOW = Date.UTC(2026, 9, 3, 2);
const core = {devices: {grandma: {role: 'host'}, bro: {role: 'client'}}};

test('grandma phone reports synced plan version and per-reminder playback', () => {
  const s = {days: {'2026-09-01': {old: {}}}};
  reportReminderStatus(core, s, 'grandma', 'grandma', {planVersion: 4, deliveries: [
    {key: '2026-10-03:r-1', state: 'played', at: NOW - 1000},
    {key: '2026-10-03:r-2', state: 'text_fallback', at: NOW - 500},
  ]}, NOW);
  assert.deepEqual(s.sync, {version: 4, at: NOW});
  assert.equal(s.days['2026-10-03']['r-1'].state, 'played');
  assert.equal(s.days['2026-10-03']['r-2'].state, 'text_fallback');
  assert.equal(s.days['2026-09-01'], undefined, 'old days trimmed');
});

test('only grandma phone may report; malformed rows rejected', () => {
  assert.throws(() => reportReminderStatus(core, {}, 'bro', 'grandma', {planVersion: 1}, NOW), {code: 'permission-denied'});
  for (const bad of [{key: 'x', state: 'played', at: NOW}, {key: '2026-10-03:r-1', state: 'heard', at: NOW},
    {key: '2026-10-03:r-1', state: 'played', at: NOW + 3600_000}]) {
    assert.throws(() => reportReminderStatus(core, {}, 'grandma', 'grandma', {planVersion: 1, deliveries: [bad]}, NOW));
  }
});
