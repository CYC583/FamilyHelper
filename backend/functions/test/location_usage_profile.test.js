// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as loc from '../src/location_state.js';
import * as usage from '../src/app_usage_state.js';
import * as profile from '../src/profile_state.js';

const core = {
  devices: {grandma: {role: 'host', name: '長輩'}, bob: {role: 'client', name: '哥哥'}, eve: {role: 'client', name: 'Eve'}},
  families: {grandma: {name: '長輩', members: {bob: {name: '哥哥'}}}},
  links: {bob: {hostId: 'grandma'}},
};
const now = Date.parse('2026-10-03T04:00:00Z');
const fails = (fn, code) => assert.throws(fn, e => e.code === code);

test('location: only grandma turns it on; family cannot locate or ring before that', () => {
  const l = {};
  fails(() => loc.requestLocate(core, l, 'bob', 'grandma', now), 'failed-precondition');
  fails(() => loc.setLocationSharing(core, l, 'bob', 'grandma', {enabled: true, disclosureVersion: 1}, now), 'permission-denied');
  fails(() => loc.setLocationSharing(core, l, 'grandma', 'grandma', {enabled: true, disclosureVersion: 0}, now), 'failed-precondition');
  const c = loc.setLocationSharing(core, l, 'grandma', 'grandma', {enabled: true, disclosureVersion: 1}, now);
  assert.equal(c.enabled, true);
  const fix = loc.reportLocation(core, l, 'grandma', 'grandma',
    {lat: 25.0330123456, lng: 121.5654, accuracy: 12.4, at: now - 1000, consentVersion: c.version}, now);
  assert.deepEqual(fix, {lat: 25.033012, lng: 121.5654, accuracy: 12, at: now - 1000, receivedAt: now});
  loc.reportLocation(core, l, 'grandma', 'grandma', {lat: 1, lng: 1, accuracy: 1, at: now - 5000, consentVersion: c.version}, now);
  assert.equal(l.latest.lat, 25.033012, 'older fix ignored');
  fails(() => loc.reportLocation(core, l, 'grandma', 'grandma', {lat: 91, lng: 1, accuracy: 1, at: now, consentVersion: c.version}, now), 'invalid-argument');
  fails(() => loc.reportLocation(core, l, 'grandma', 'grandma', {lat: 1, lng: 1, accuracy: 1, at: now, consentVersion: 99}, now), 'failed-precondition');
  fails(() => loc.reportLocation(core, l, 'bob', 'grandma', {lat: 1, lng: 1, accuracy: 1, at: now, consentVersion: c.version}, now), 'permission-denied');
});

test('locate and ring: members only, with cooldowns; pausing deletes the position', () => {
  const l = {};
  loc.setLocationSharing(core, l, 'grandma', 'grandma', {enabled: true, disclosureVersion: 1}, now);
  fails(() => loc.requestLocate(core, l, 'eve', 'grandma', now), 'permission-denied');
  loc.requestLocate(core, l, 'bob', 'grandma', now);
  fails(() => loc.requestLocate(core, l, 'bob', 'grandma', now + 1000), 'resource-exhausted');
  loc.requestLocate(core, l, 'bob', 'grandma', now + loc.LOCATE_COOLDOWN_MS);
  assert.deepEqual(loc.ringHost(core, l, 'bob', 'grandma', now), {by: 'bob', name: '哥哥', at: now});
  fails(() => loc.ringHost(core, l, 'bob', 'grandma', now + 5000), 'resource-exhausted');
  l.latest = {lat: 1};
  loc.setLocationSharing(core, l, 'grandma', 'grandma', {enabled: false}, now);
  assert.equal(l.latest, undefined);
  assert.equal(l.ring, undefined);
  fails(() => loc.ringHost(core, l, 'bob', 'grandma', now + 60_000), 'failed-precondition');
});

test('app usage: consent, validation, sorting, 7-day retention, pause deletes', () => {
  const u = {};
  const base = {date: '2026-10-03', apps: [{name: 'LINE', minutes: 30}, {name: 'YouTube', minutes: 95}]};
  fails(() => usage.reportAppUsage(core, u, 'grandma', 'grandma', {...base, consentVersion: 1}, now), 'failed-precondition');
  const c = usage.setAppUsageSharing(core, u, 'grandma', 'grandma', {enabled: true, disclosureVersion: 1}, now);
  const day = usage.reportAppUsage(core, u, 'grandma', 'grandma', {...base, consentVersion: c.version}, now);
  assert.deepEqual(day.apps.map(a => a.name), ['YouTube', 'LINE']);
  assert.equal(day.total, 125);
  fails(() => usage.reportAppUsage(core, u, 'grandma', 'grandma', {...base, date: '2026-10-01', consentVersion: c.version}, now), 'invalid-argument');
  fails(() => usage.reportAppUsage(core, u, 'grandma', 'grandma',
    {date: '2026-10-03', apps: [{name: '<b>', minutes: 1}], consentVersion: c.version}, now), 'invalid-argument');
  fails(() => usage.reportAppUsage(core, u, 'bob', 'grandma', {...base, consentVersion: c.version}, now), 'permission-denied');
  u.days['2026-09-20'] = {apps: []};
  usage.reportAppUsage(core, u, 'grandma', 'grandma', {...base, consentVersion: c.version}, now);
  assert.deepEqual(Object.keys(u.days), ['2026-10-03']);
  usage.setAppUsageSharing(core, u, 'grandma', 'grandma', {enabled: false}, now);
  assert.equal(u.days, undefined);
});

test('profile: names validated and copied to the family; avatar must be a small JPEG', () => {
  const s = structuredClone(core);
  assert.equal(profile.setProfileName(s, 'bob', '小明', now), 'grandma');
  assert.equal(s.families.grandma.members.bob.name, '小明');
  assert.equal(s.devices.bob.name, '小明');
  assert.equal(profile.setProfileName(s, 'grandma', '阿嬤', now), 'grandma');
  assert.equal(s.families.grandma.name, '阿嬤');
  assert.throws(() => profile.cleanName(''), e => e.code === 'invalid-argument');
  assert.throws(() => profile.cleanName('一二三四五六七八九十一二三'), e => e.code === 'invalid-argument');
  assert.equal(profile.cleanName(' 小美 '), '小美');
  const jpeg = Buffer.concat([Buffer.from([0xff, 0xd8]), Buffer.alloc(200, 1), Buffer.from([0xff, 0xd9])]).toString('base64');
  assert.equal(profile.cleanAvatar(jpeg), jpeg);
  assert.throws(() => profile.cleanAvatar(Buffer.alloc(200, 1).toString('base64')), e => e.code === 'invalid-argument');
  assert.throws(() => profile.cleanAvatar('A'.repeat(profile.MAX_AVATAR_BASE64 + 4)), e => e.code === 'invalid-argument');
});

test('a name chosen in the profile page survives the app re-registering at start', async () => {
  const {register} = await import('../src/state.js');
  const s = {devices: {}, families: {}};
  register(s, 'grandma', 'host', '長輩', 1);
  register(s, 'bob', 'client', '哥哥', 1);
  s.links = {bob: {hostId: 'grandma'}};
  s.families.grandma.members = {bob: {name: '哥哥'}};
  register(s, 'bob', 'client', '哥哥-pairing', 2);
  assert.equal(s.devices.bob.name, '哥哥-pairing', 'before any profile change, registration may rename');
  profile.setProfileName(s, 'bob', '小明', 3);
  profile.setProfileName(s, 'grandma', '林緣', 3);
  register(s, 'bob', 'client', '哥哥', 4);
  register(s, 'grandma', 'host', '長輩', 4);
  assert.equal(s.devices.bob.name, '小明');
  assert.equal(s.families.grandma.members.bob.name, '小明');
  assert.equal(s.devices.grandma.name, '林緣');
  assert.equal(s.families.grandma.name, '林緣');
});
