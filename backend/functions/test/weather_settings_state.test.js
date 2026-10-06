// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';
import {setWeatherSettings} from '../src/weather_settings_state.js';

const family = () => ({
  core: {
    devices: {grandma: {role: 'host'}, alice: {role: 'client'}, stranger: {role: 'client'}},
    families: {grandma: {members: {alice: true}}},
    links: {alice: {hostId: 'grandma'}},
  },
});
const choice = {
  expectedVersion: 0,
  city: {name: '台北市', latitude: 25.05306, longitude: 121.52639},
  morningTime: '08:30',
};

test('paired family member sets one versioned morning city/time, no GPS or secret data', () => {
  const root = family();
  const out = setWeatherSettings(root, 'alice', 'grandma', choice, 1000);
  assert.deepEqual(out, {
    version: 1,
    city: choice.city,
    morningTime: '08:30',
    timezone: 'Asia/Taipei',
    updatedAt: 1000,
    updatedBy: 'alice',
  });
  assert.deepEqual(root.care.grandma.settings.weather, out);
  assert.equal(root.core.families.grandma.members.alice, true);
});

test('unpaired, wrong role, stale version and malformed time/city are rejected', () => {
  const root = family();
  for (const [uid, input] of [
    ['stranger', choice],
    ['grandma', choice],
    ['alice', {...choice, morningTime: '8:30'}],
    ['alice', {...choice, city: {...choice.city, latitude: 999}}],
    ['alice', {...choice, expectedVersion: 1}],
  ]) {
    assert.throws(() => setWeatherSettings(root, uid, 'grandma', input, 1000));
  }
  assert.equal(root.care, undefined);
});

test('two family writes with the same version cannot silently overwrite', () => {
  const root = family();
  root.core.devices.bob = {role: 'client'};
  root.core.families.grandma.members.bob = true;
  root.core.links.bob = {hostId: 'grandma'};
  setWeatherSettings(root, 'alice', 'grandma', choice, 1000);
  assert.throws(() => setWeatherSettings(root, 'bob', 'grandma', choice, 1001));
  assert.equal(root.care.grandma.settings.weather.updatedBy, 'alice');
});
