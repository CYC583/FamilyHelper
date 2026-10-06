// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import {before, beforeEach, after, test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {initializeTestEnvironment, assertFails, assertSucceeds} from '@firebase/rules-unit-testing';
import {ref, get, set, query, orderByChild, limitToLast} from 'firebase/database';

const projectId = 'demo-familyhelper';
let env;
const database = uid => env.authenticatedContext(uid).database();
const adminSet = (path, value) => env.withSecurityRulesDisabled(async context =>
  set(ref(context.database(), path), value));

function seed() {
  const members = Object.fromEntries(['alice', 'bob', 'carol', 'dave'].map(uid => [uid, {name: uid}]));
  return {
    core: {
      devices: {grandma: {role: 'host'}, alice: {role: 'client'}, bob: {role: 'client'},
        carol: {role: 'client'}, dave: {role: 'client'}, eve: {role: 'client'}},
      links: Object.fromEntries(Object.keys(members).map(uid => [uid, {hostId: 'grandma'}])),
      families: {grandma: {members}},
    },
    care: {grandma: {
      settings: {
        weather: {version: 1, city: {name: '台北市', latitude: 25.03, longitude: 121.56}, morningTime: '08:30'},
        reminders: {version: 1, timezone: 'Asia/Taipei', items: [{type: 'water', time: '14:00', text: ''}]},
      },
      battery: {
        consent: {hostUid: 'grandma', enabled: true, status: 'enabled', version: 1,
          disclosureVersion: 2, updatedAt: 1},
        latest: {batteryPercent: 22, charging: false, observedAt: 2, receivedAt: 3, sampleSeq: 2},
        episode: {id: 'ep-1', status: 'active'},
        events: {'ep-1': {createdAt: 4, severity: 'low', lastObservedAt: 5}},
        preferences: {alice: {enabled: true, soundEnabled: false},
          bob: {enabled: true, soundEnabled: true}},
        pushOps: {'ep-1': {alice: {status: 'accepted', attempts: 1, token: 'secret'}}},
      },
      sound: {latest: {muted: true}}, screenTime: {latest: {minutes: 999}},
    }},
  };
}

before(async () => {
  const address = process.env.FIREBASE_DATABASE_EMULATOR_HOST;
  if (!address || !/^(localhost|127\.0\.0\.1):\d+$/.test(address)) {
    throw new Error('Battery rules tests require a local RTDB emulator');
  }
  for (const key of ['HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy']) delete process.env[key];
  const [host, port] = address.split(':');
  env = await initializeTestEnvironment({projectId, database: {
    host, port: Number(port),
    rules: readFileSync(new URL('../../database.rules.json', import.meta.url), 'utf8'),
  }});
});

test('weather setting is readable only by the host and current family, never directly writable', async () => {
  for (const uid of ['grandma', 'alice', 'bob', 'carol', 'dave']) {
    await assertFails(get(ref(database(uid), 'care/grandma/settings')));
    const weather = (await assertSucceeds(get(ref(database(uid), 'care/grandma/settings/weather')))).val();
    assert.equal(weather.morningTime, '08:30');
    await assertFails(set(ref(database(uid), 'care/grandma/settings/weather/morningTime'), '03:00'));
  }
  await assertFails(get(ref(database('eve'), 'care/grandma/settings/weather')));
  await adminSet('core/families/grandma/members/alice', null);
  await adminSet('core/links/alice', null);
  await assertFails(get(ref(database('alice'), 'care/grandma/settings/weather')));
});
test('reminder plan has the same scoped read and server-only write boundary', async () => {
  for (const uid of ['grandma', 'alice', 'bob', 'carol', 'dave']) {
    const plan = (await assertSucceeds(get(ref(database(uid), 'care/grandma/settings/reminders')))).val();
    assert.equal(plan.items[0].type, 'water');
    await assertFails(set(ref(database(uid), 'care/grandma/settings/reminders/version'), 99));
  }
  await assertFails(get(ref(database('eve'), 'care/grandma/settings/reminders')));
  await adminSet('core/families/grandma/members/alice', null);
  await adminSet('core/links/alice', null);
  await assertFails(get(ref(database('alice'), 'care/grandma/settings/reminders')));
});
beforeEach(async () => { await env.clearDatabase(); await adminSet('/', seed()); });
after(async () => env?.cleanup());

test('no parent read; host and four members can read only minimal consent', async () => {
  for (const uid of ['grandma', 'alice', 'bob', 'carol', 'dave']) {
    await assertFails(get(ref(database(uid), 'care/grandma')));
    await assertFails(get(ref(database(uid), 'care/grandma/battery')));
    const consent = (await assertSucceeds(get(ref(database(uid), 'care/grandma/battery/consent')))).val();
    assert.equal(consent.enabled, true);
    assert.equal(JSON.stringify(consent).includes('batteryPercent'), false);
  }
  await assertFails(get(ref(database('eve'), 'care/grandma/battery/consent')));
  await assertFails(get(ref(env.unauthenticatedContext().database(), 'care/grandma/battery/consent')));
});

test('consent enables scoped latest/episode/event but not sound, screen or private push ops', async () => {
  for (const uid of ['grandma', 'alice', 'bob', 'carol', 'dave']) {
    assert.equal((await assertSucceeds(get(ref(database(uid), 'care/grandma/battery/latest')))).val().batteryPercent, 22);
    await assertSucceeds(get(ref(database(uid), 'care/grandma/battery/episode')));
    await assertSucceeds(get(ref(database(uid), 'care/grandma/battery/events/ep-1')));
    await assertFails(get(ref(database(uid), 'care/grandma/sound/latest')));
    await assertFails(get(ref(database(uid), 'care/grandma/screenTime/latest')));
    await assertFails(get(ref(database(uid), 'care/grandma/battery/pushOps')));
  }
  await assertFails(get(ref(database('eve'), 'care/grandma/battery/latest')));
});

test('old disclosure cannot expose detailed battery values even when consent says enabled', async () => {
  await adminSet('care/grandma/battery/consent/disclosureVersion', null);
  await assertSucceeds(get(ref(database('alice'), 'care/grandma/battery/consent')));
  await assertFails(get(ref(database('alice'), 'care/grandma/battery/latest')));
  await assertFails(get(ref(database('alice'), 'care/grandma/battery/episode')));
  await assertFails(get(query(ref(database('alice'), 'care/grandma/battery/events'),
    orderByChild('createdAt'), limitToLast(50))));
  await assertFails(get(ref(database('alice'), 'care/grandma/battery/events/ep-1')));
});

test('event list requires createdAt order and limit <= 50', async () => {
  const events = ref(database('alice'), 'care/grandma/battery/events');
  await assertFails(get(events));
  await assertFails(get(query(events, orderByChild('createdAt'))));
  await assertFails(get(query(events, limitToLast(50))));
  await assertFails(get(query(events, orderByChild('createdAt'), limitToLast(51))));
  const result = await assertSucceeds(get(query(events, orderByChild('createdAt'), limitToLast(50))));
  assert.equal(Object.keys(result.val()).length, 1);
});

test('each current member reads only own preference; every app direct write is denied', async () => {
  await assertSucceeds(get(ref(database('alice'), 'care/grandma/battery/preferences/alice')));
  await assertFails(get(ref(database('alice'), 'care/grandma/battery/preferences/bob')));
  await assertFails(get(ref(database('alice'), 'care/grandma/battery/preferences')));
  await assertFails(get(ref(database('grandma'), 'care/grandma/battery/preferences/alice')));
  for (const uid of ['grandma', 'alice']) {
    await assertFails(set(ref(database(uid), 'care/grandma/battery/consent/enabled'), false));
    await assertFails(set(ref(database(uid), 'care/grandma/battery/latest/batteryPercent'), 1));
    await assertFails(set(ref(database(uid), 'care/grandma/battery/events/fake'), {createdAt: 6}));
  }
});

test('pause/revoke and unpair remove detailed read access without exposing stale latest', async () => {
  await adminSet('care/grandma/battery/consent',
    {hostUid: 'grandma', enabled: false, status: 'paused', version: 2, updatedAt: 6});
  const status = (await assertSucceeds(get(ref(database('alice'), 'care/grandma/battery/consent')))).val();
  assert.equal(status.status, 'paused');
  await assertFails(get(ref(database('alice'), 'care/grandma/battery/latest')));
  await assertFails(get(ref(database('alice'), 'care/grandma/battery/events/ep-1')));
  await adminSet('care/grandma/battery/consent',
    {hostUid: 'grandma', enabled: true, status: 'enabled', version: 3,
      disclosureVersion: 2, updatedAt: 7});
  await adminSet('core/families/grandma/members/alice', null);
  await adminSet('core/links/alice', null);
  await assertFails(get(ref(database('alice'), 'care/grandma/battery/consent')));
  await assertFails(get(ref(database('alice'), 'care/grandma/battery/latest')));
});
