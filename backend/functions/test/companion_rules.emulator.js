// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import {before, beforeEach, after, test} from 'node:test';
import {readFileSync} from 'node:fs';
import {initializeTestEnvironment, assertFails, assertSucceeds} from '@firebase/rules-unit-testing';
import {ref, get, set} from 'firebase/database';

let env;
const database = uid => env.authenticatedContext(uid).database();
const adminSet = (path, value) => env.withSecurityRulesDisabled(async context =>
  set(ref(context.database(), path), value));
const members = Object.fromEntries(['alice', 'bob', 'carol', 'dave'].map(uid => [uid, {name: uid}]));
const seed = () => ({
  core: {
    devices: {grandma: {role: 'host'}, alice: {role: 'client'}, bob: {role: 'client'},
      carol: {role: 'client'}, dave: {role: 'client'}, eve: {role: 'client'}},
    links: Object.fromEntries(Object.keys(members).map(uid => [uid, {hostId: 'grandma'}])),
    families: {grandma: {members, photoConsent: {enabled: true, version: 1, shareGeneration: 1}}},
  },
  care: {grandma: {
    battery: {consent: {enabled: true, status: 'enabled', disclosureVersion: 2}},
    companion: {
      consent: {enabled: true, status: 'enabled', disclosureVersion: 1, version: 1,
        items: {responses: true, mood: false, sound: true}},
      responses: {'2026-10-02': {medicine_0800: {type: 'medicine', time: '08:00', response: 'done'}}},
      mood: {'2026-10-02': {mood: 'good'}},
      sound: {latest: {ringer: 'silent'}, episode: {id: 'x'}},
      liveness: {state: 'suspected'},
    },
    messages: {items: {m1: {authorId: 'alice', kind: 'text', text: '早安'}}},
    photoReactions: {p1: {alice: {heart: true}}},
    places: {consent: {enabled: true, status: 'enabled', disclosureVersion: 1, version: 1},
      events: {e1: {place: 'home', transition: 'exit', at: 1}}},
  }},
});

before(async () => {
  const address = process.env.FIREBASE_DATABASE_EMULATOR_HOST;
  if (!address || !/^(localhost|127\.0\.0\.1):\d+$/.test(address)) throw new Error('Requires a local RTDB emulator');
  for (const key of ['HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy']) delete process.env[key];
  const [host, port] = address.split(':');
  env = await initializeTestEnvironment({projectId: 'demo-familyhelper', database: {host, port: Number(port),
    rules: readFileSync(new URL('../../database.rules.json', import.meta.url), 'utf8')}});
});
beforeEach(async () => { await env.clearDatabase(); await adminSet('/', seed()); });
after(async () => env?.cleanup());

test('companion items are readable only per accepted item, never as a parent node', async () => {
  for (const uid of ['grandma', 'alice', 'dave']) {
    await assertSucceeds(get(ref(database(uid), 'care/grandma/companion/consent')));
    await assertSucceeds(get(ref(database(uid), 'care/grandma/companion/responses/2026-10-02')));
    await assertSucceeds(get(ref(database(uid), 'care/grandma/companion/sound/latest')));
    // The host always reads her own data; family needs the mood item.
    if (uid === 'grandma') await assertSucceeds(get(ref(database(uid), 'care/grandma/companion/mood/2026-10-02')));
    else await assertFails(get(ref(database(uid), 'care/grandma/companion/mood/2026-10-02')));
    await assertFails(get(ref(database(uid), 'care/grandma/companion')));
    await assertFails(get(ref(database(uid), 'care/grandma/companion/responses')));
    await assertFails(get(ref(database(uid), 'care/grandma/companion/sound/episode')));
    await assertFails(get(ref(database(uid), 'care/grandma')));
  }
  for (const path of ['consent', 'responses/2026-10-02', 'sound/latest', 'liveness']) {
    await assertFails(get(ref(database('eve'), `care/grandma/companion/${path}`)));
  }
});

test('pause hides shared replies and sound immediately; clients can never write', async () => {
  await adminSet('care/grandma/companion/consent/status', 'paused');
  await adminSet('care/grandma/companion/consent/enabled', false);
  await assertFails(get(ref(database('alice'), 'care/grandma/companion/responses/2026-10-02')));
  await assertFails(get(ref(database('alice'), 'care/grandma/companion/sound/latest')));
  await assertSucceeds(get(ref(database('alice'), 'care/grandma/companion/consent')));
  for (const uid of ['grandma', 'alice']) {
    await assertFails(set(ref(database(uid), 'care/grandma/companion/consent/enabled'), true));
    await assertFails(set(ref(database(uid), 'care/grandma/companion/responses/2026-10-03/x'), {response: 'done'}));
    await assertFails(set(ref(database(uid), 'care/grandma/messages/items/new'), {text: 'x'}));
    await assertFails(set(ref(database(uid), 'care/grandma/photoReactions/p1/alice'), {heart: false}));
  }
});

test('old disclosure version hides companion data until grandma re-consents', async () => {
  await adminSet('care/grandma/companion/consent/disclosureVersion', 0);
  await assertFails(get(ref(database('bob'), 'care/grandma/companion/responses/2026-10-02')));
});

test('messages and reactions follow membership; reactions also follow photo consent', async () => {
  await assertSucceeds(get(ref(database('bob'), 'care/grandma/messages/items')));
  await assertSucceeds(get(ref(database('bob'), 'care/grandma/photoReactions/p1')));
  await assertFails(get(ref(database('eve'), 'care/grandma/messages/items')));
  await assertFails(get(ref(database('bob'), 'care/grandma/photoReactions')));
  await adminSet('core/families/grandma/photoConsent/enabled', false);
  await assertFails(get(ref(database('bob'), 'care/grandma/photoReactions/p1')));
  await adminSet('core/families/grandma/members/bob', null);
  await adminSet('core/links/bob', null);
  await assertFails(get(ref(database('bob'), 'care/grandma/messages/items')));
});

test('suspected offline marker follows battery sharing consent', async () => {
  await assertSucceeds(get(ref(database('carol'), 'care/grandma/companion/liveness')));
  await adminSet('care/grandma/battery/consent/status', 'paused');
  await assertFails(get(ref(database('carol'), 'care/grandma/companion/liveness')));
});

test('place events are readable only while grandma keeps leave/arrive alerts on', async () => {
  await assertSucceeds(get(ref(database('alice'), 'care/grandma/places/events')));
  await assertSucceeds(get(ref(database('alice'), 'care/grandma/places/consent')));
  await assertFails(get(ref(database('eve'), 'care/grandma/places/events')));
  await assertFails(set(ref(database('grandma'), 'care/grandma/places/events/x'), {place: 'home'}));
  await adminSet('care/grandma/places/consent/status', 'paused');
  await assertFails(get(ref(database('alice'), 'care/grandma/places/events')));
  await assertSucceeds(get(ref(database('alice'), 'care/grandma/places/consent')));
});

test('location, app usage and avatars: family reads only after grandma consents; nobody writes directly', async () => {
  const on = {enabled: true, status: 'enabled', disclosureVersion: 1, version: 1};
  await adminSet('care/grandma/location', {consent: {...on, enabled: false, status: 'paused'},
    latest: {lat: 25, lng: 121, accuracy: 10, at: 1}});
  await adminSet('care/grandma/appUsage', {consent: {...on, enabled: false, status: 'paused'},
    days: {'2026-10-03': {apps: [{name: 'LINE', minutes: 3}]}}});
  await adminSet('avatars/grandma', {alice: {jpegBase64: 'x'}, grandma: {jpegBase64: 'y'}});
  // Paused: family cannot read coordinates or usage; grandma still can.
  await assertFails(get(ref(database('alice'), 'care/grandma/location/latest')));
  await assertFails(get(ref(database('alice'), 'care/grandma/appUsage/days/2026-10-03')));
  await assertSucceeds(get(ref(database('alice'), 'care/grandma/location/consent')));
  await assertSucceeds(get(ref(database('grandma'), 'care/grandma/location/latest')));
  await adminSet('care/grandma/location/consent', on);
  await adminSet('care/grandma/appUsage/consent', on);
  await assertSucceeds(get(ref(database('alice'), 'care/grandma/location/latest')));
  await assertSucceeds(get(ref(database('alice'), 'care/grandma/appUsage/days/2026-10-03')));
  await assertFails(get(ref(database('alice'), 'care/grandma/location')));
  await assertFails(get(ref(database('eve'), 'care/grandma/location/latest')));
  await assertFails(get(ref(database('eve'), 'care/grandma/appUsage/days/2026-10-03')));
  await assertFails(set(ref(database('grandma'), 'care/grandma/location/latest'), {lat: 1}));
  await assertFails(set(ref(database('alice'), 'care/grandma/location/consent/enabled'), true));
  // Avatars: same family only, written only by the server.
  await assertSucceeds(get(ref(database('alice'), 'avatars/grandma')));
  await assertSucceeds(get(ref(database('grandma'), 'avatars/grandma')));
  await assertFails(get(ref(database('eve'), 'avatars/grandma')));
  await assertFails(set(ref(database('alice'), 'avatars/grandma/alice'), {jpegBase64: 'z'}));
});
