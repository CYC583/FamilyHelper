// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';
import {createCompanionGateway, decodeVoice} from '../src/care_companion_gateway.js';

const NOW = Date.UTC(2026, 9, 2, 2);
const fails = (action, code) => assert.rejects(action, error => error.code === code);
// Minimal MP4 header: size + 'ftyp' + brand, padded to the minimum length.
const m4a = (fill = 1) => Buffer.concat([Buffer.from([0, 0, 0, 24]), Buffer.from('ftypM4A '), Buffer.alloc(80, fill)]);

function fixture({saveFails = false} = {}) {
  const root = {
    core: {devices: {grandma: {role: 'host'}, alice: {role: 'client'}, bob: {role: 'client'}, eve: {role: 'client'}},
      families: {grandma: {members: {alice: {name: 'A'}, bob: {name: 'B'}}}},
      links: {alice: {hostId: 'grandma'}, bob: {hostId: 'grandma'}}},
    care: {grandma: {}},
  };
  const objects = new Map();
  const pushes = [];
  const at = path => path.split('/').filter(Boolean).reduce((node, key) => node?.[key], root.care);
  const bucket = {file: path => ({
    save: async bytes => { if (saveFails) throw Object.assign(new Error('x'), {code: 503}); objects.set(path, Buffer.from(bytes)); },
    download: async () => { if (!objects.has(path)) throw Object.assign(new Error('gone'), {code: 404}); return [objects.get(path)]; },
    delete: async () => { if (!objects.delete(path)) throw Object.assign(new Error('gone'), {code: 404}); },
  })};
  let now = NOW;
  let seq = 0;
  const gateway = createCompanionGateway({
    readCore: async () => structuredClone(root.core),
    readCare: async (hostId, child) => structuredClone(at(`${hostId}/${child}`) ?? null),
    transactCare: async (hostId, child, update) => {
      const keys = `${hostId}/${child}`.split('/').filter(Boolean);
      let parent = root.care;
      for (const key of keys.slice(0, -1)) parent = parent[key] ??= {};
      const current = structuredClone(parent[keys.at(-1)] ?? {});
      update(current);
      parent[keys.at(-1)] = current;
      return structuredClone(current);
    },
    bucket, notify: async (uids, title, body, data) => { pushes.push({uids, title, body, data}); return {accepted: uids.length}; },
    now: () => now, newId: () => `id-${++seq}`,
  });
  return {root, objects, pushes, gateway, tick: ms => { now += ms; }};
}

test('voice note is published only after its private object exists; push carries no content', async () => {
  const {root, objects, pushes, gateway} = fixture();
  const audio = m4a();
  const sent = await gateway.sendCareMessage('alice', {hostId: 'grandma', kind: 'voice',
    durationMs: 8000, audioBase64: audio.toString('base64')});
  assert.equal(root.care.grandma.messages.items[sent.id].status, 'ready');
  assert.ok(objects.has(`care-voice/grandma/${sent.id}.m4a`));
  assert.deepEqual(pushes[0].uids.sort(), ['bob', 'grandma']);
  assert.deepEqual(Object.keys(pushes[0].data).sort(), ['hostId', 'type']);
  const played = await gateway.getVoiceMessage('grandma', {hostId: 'grandma', id: sent.id});
  assert.equal(Buffer.from(played.audioBase64, 'base64').equals(audio), true);
  await fails(() => gateway.getVoiceMessage('eve', {hostId: 'grandma', id: sent.id}), 'permission-denied');
});

test('failed object write leaves an unplayable pending row, and tampered audio is refused', async () => {
  const failing = fixture({saveFails: true});
  await fails(() => failing.gateway.sendCareMessage('alice', {hostId: 'grandma', kind: 'voice', durationMs: 3000,
    audioBase64: m4a().toString('base64')}), 'unavailable');
  assert.equal(failing.root.care.grandma.messages.items['id-1'].status, 'pending');
  await fails(() => failing.gateway.getVoiceMessage('bob', {hostId: 'grandma', id: 'id-1'}), 'not-found');
  assert.equal(failing.pushes.length, 0);

  const {objects, gateway} = fixture();
  const sent = await gateway.sendCareMessage('alice', {hostId: 'grandma', kind: 'voice', durationMs: 3000,
    audioBase64: m4a().toString('base64')});
  objects.set(`care-voice/grandma/${sent.id}.m4a`, m4a(9));
  await fails(() => gateway.getVoiceMessage('bob', {hostId: 'grandma', id: sent.id}), 'data-loss');
});

test('non-MP4, oversized and non-base64 voice payloads are rejected before any write', () => {
  for (const value of ['', 'not base64!', Buffer.from('hello world').toString('base64'),
    Buffer.concat([m4a(), Buffer.alloc(400_001)]).toString('base64')]) {
    assert.throws(() => decodeVoice(value), {code: 'invalid-argument'});
  }
});

test('maintenance removes orphaned voice objects and notifies a suspected outage once', async () => {
  const {root, objects, pushes, gateway, tick} = fixture({});
  const sent = await gateway.sendCareMessage('alice', {hostId: 'grandma', kind: 'voice', durationMs: 3000,
    audioBase64: m4a().toString('base64')});
  delete root.core.families.grandma.members.alice; delete root.core.links.alice;
  root.care.grandma.battery = {consent: {enabled: true, status: 'enabled', disclosureVersion: 2, updatedAt: NOW - 5 * 3600_000},
    latest: {receivedAt: NOW - 4 * 3600_000}, preferences: {bob: {enabled: true}}};
  pushes.length = 0;
  const first = await gateway.maintenance(['grandma']);
  assert.equal(first.voiceDeleted, 1);
  assert.equal(objects.has(`care-voice/grandma/${sent.id}.m4a`), false);
  assert.equal(first.offlineNotified, 1);
  assert.deepEqual(pushes.map(p => p.data.type), ['offline']);
  tick(30 * 60_000);
  assert.equal((await gateway.maintenance(['grandma'])).offlineNotified, 0);
});

test('companion consent and sound alert go through the host-only transitions', async () => {
  const {pushes, gateway, tick} = fixture();
  await fails(() => gateway.setCompanionConsent('alice', {action: 'enable', items: {sound: true}, disclosureVersion: 1}),
    'permission-denied');
  const consent = await gateway.setCompanionConsent('grandma', {action: 'enable', items: {sound: true}, disclosureVersion: 1});
  const report = async () => gateway.reportSoundStatus('grandma', {ringer: 'silent', dnd: false, mediaZero: false,
    observedAt: NOW + elapsed, consentVersion: consent.version});
  let elapsed = 0;
  assert.equal((await report()).notified, false);
  elapsed = 61 * 60_000; tick(elapsed);
  assert.equal((await report()).notified, true);
  assert.equal(pushes.at(-1).data.type, 'sound');
  assert.deepEqual(pushes.at(-1).uids.sort(), ['alice', 'bob']);
});
