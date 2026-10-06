// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import {before, beforeEach, after, test} from 'node:test';
import {readFileSync} from 'node:fs';
import {initializeTestEnvironment, assertFails, assertSucceeds} from '@firebase/rules-unit-testing';
import {ref, get, set} from 'firebase/database';
import assert from 'node:assert/strict';
import * as model from '../src/state.js';

let env;
const id = 'demo-familyhelper';
const database = uid => env.authenticatedContext(uid).database();
const now = Date.now();
function seed(status = 'accepted') {
  return {core: {
    devices: {grandma: {role: 'host'}, alice: {role: 'client'}, bob: {role: 'client'}, carol: {role: 'client'}, dave: {role: 'client'}, eve: {role: 'client'}},
    links: {alice: {hostId: 'grandma'}, bob: {hostId: 'grandma'}, carol: {hostId: 'grandma'}, dave: {hostId: 'grandma'}},
    families: {grandma: {members: {alice: {name: 'Alice'}, bob: {name: 'Bob'}, carol: {name: 'Carol'}, dave: {name: 'Dave'}}, activeSessionId: 'session'}},
    sessions: {session: {hostId: 'grandma', clientId: 'alice', status, createdAt: now, expiresAt: now + 900_000, leaseUntil: now + 600_000}},
    pairCodes: {secretHash: {hostId: 'grandma', expiresAt: now + 300_000}},
  }, pushTokens: {grandma: {token: 'private'}}};
}
async function adminSet(path, value) { await env.withSecurityRulesDisabled(async c => set(ref(c.database(), path), value)); }
before(async () => {
  if (!process.env.FIREBASE_DATABASE_EMULATOR_HOST) throw new Error('Run this test through firebase emulators:exec --only database');
  const [host, port] = process.env.FIREBASE_DATABASE_EMULATOR_HOST.split(':');
  if (!['127.0.0.1', 'localhost'].includes(host)) throw new Error('This test only supports a local emulator');
  // The RTDB Node WebSocket transport ignores NO_PROXY. Disable its proxy
  // variables only in this isolated test process, whose destination is loopback.
  for (const key of ['HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy']) delete process.env[key];
  env = await initializeTestEnvironment({projectId: id, database: {host, port: Number(port), rules: readFileSync(new URL('../../database.rules.json', import.meta.url), 'utf8')}});
});
beforeEach(async () => { await env.clearDatabase(); await adminSet('/', seed()); });
after(async () => env?.cleanup());
test('anonymous unauthenticated caller cannot read family', async () => {
  await assertFails(get(ref(env.unauthenticatedContext().database(), 'core/families/grandma')));
});
test('unbound authenticated device cannot read family, code or tokens', async () => {
  await assertFails(get(ref(database('eve'), 'core/families/grandma')));
  await assertFails(get(ref(database('grandma'), 'core/pairCodes')));
  await assertFails(get(ref(database('alice'), 'pushTokens/grandma')));
});
test('all four bound family members can read, but fifth cannot write membership or consent', async () => {
  for (const uid of ['alice', 'bob', 'carol', 'dave']) {
    await assertSucceeds(get(ref(database(uid), 'core/families/grandma')));
  }
  await assertFails(set(ref(database('alice'), 'core/families/grandma/members/eve'), {name: 'Eve'}));
  await assertFails(set(ref(database('alice'), 'core/sessions/session/status'), 'accepted'));
});
test('private photo operation ledger is unreadable even to the host and current family members', async () => {
  await adminSet('core/photoOps/grandma/op-1', {
    mediaId: 'media-1', authorId: 'alice', status: 'pending', sha256: 'a'.repeat(64),
    objectPath: 'care-photos/grandma/media-1.jpg',
  });
  for (const uid of ['grandma', 'alice', 'bob', 'eve']) {
    await assertFails(get(ref(database(uid), 'core/photoOps/grandma')));
    await assertFails(get(ref(database(uid), 'core/photoOps/grandma/op-1')));
  }
  await assertSucceeds(get(ref(database('alice'), 'core/families/grandma')));
});
test('only host can create offer, only active client can create answer', async () => {
  const offer = {type: 'offer', sdp: 'v=0', screenStreamId: 'screen'};
  await assertFails(set(ref(database('alice'), 'signals/session/offer'), offer));
  await assertSucceeds(set(ref(database('grandma'), 'signals/session/offer'), offer));
  await assertFails(set(ref(database('grandma'), 'signals/session/offer'), offer));
  await assertFails(set(ref(database('bob'), 'signals/session/answer'), {type: 'answer', sdp: 'v=0'}));
  await assertSucceeds(set(ref(database('alice'), 'signals/session/answer'), {type: 'answer', sdp: 'v=0'}));
});
test('sibling cannot read active session signal', async () => {
  await assertFails(get(ref(database('bob'), 'signals/session')));
});
test('signal cannot be exchanged before host acceptance', async () => {
  await adminSet('core/sessions/session/status', 'pending');
  await assertFails(set(ref(database('grandma'), 'signals/session/offer'), {type: 'offer', sdp: 'v=0', screenStreamId: 'screen'}));
});
test('lease expiry blocks even an otherwise accepted session', async () => {
  await adminSet('core/sessions/session/leaseUntil', Date.now() - 1);
  await assertFails(get(ref(database('alice'), 'signals/session')));
});
test('revoked client loses family and signal access immediately', async () => {
  await adminSet('core/families/grandma/members/alice', null);
  await assertFails(get(ref(database('alice'), 'core/families/grandma')));
  await assertFails(get(ref(database('alice'), 'signals/session')));
});
test('SDP shape and size are bounded', async () => {
  await assertFails(set(ref(database('grandma'), 'signals/session/offer'), {type: 'offer', sdp: 'x'.repeat(131073), screenStreamId: 'screen'}));
  await assertFails(set(ref(database('grandma'), 'signals/session/offer'), {type: 'offer', sdp: 'v=0', screenStreamId: 'screen', extra: 'no'}));
});
test('ICE is limited to 128 write-once slots and the sender owns only its lane', async () => {
  const ice = {candidate: 'candidate:1', sdpMid: '0', sdpMLineIndex: 0};
  await assertSucceeds(set(ref(database('alice'), 'signals/session/ice/client/0'), ice));
  await assertFails(set(ref(database('alice'), 'signals/session/ice/client/0'), ice));
  await assertFails(set(ref(database('alice'), 'signals/session/ice/host/0'), ice));
  await assertFails(set(ref(database('alice'), 'signals/session/ice/client/128'), ice));
  await assertFails(set(ref(database('alice'), 'signals/session/ice/client/01'), ice));
});
test('RTDB compare-and-swap allows only one concurrent help reservation', async () => {
  await adminSet('core/families/grandma/activeSessionId', null);
  const address = process.env.FIREBASE_DATABASE_EMULATOR_HOST;
  const url = `http://${address}/core.json?ns=${id}`;
  // Exercise the emulator's real optimistic concurrency with independent HTTP
  // clients. No production credentials; destination was checked as loopback.
  async function reserve(uid) {
    for (let attempt = 0; attempt < 5; attempt++) {
      const response = await fetch(url, {headers: {Authorization: 'Bearer owner', 'X-Firebase-ETag': 'true'}});
      assert.equal(response.status, 200);
      const current = await response.json();
      try { model.requestSession(current, uid, 'grandma', uid, Date.now()); }
      catch (e) { if (e.code === 'already-exists') return false; throw e; }
      const write = await fetch(url, {method: 'PUT', headers: {Authorization: 'Bearer owner', 'Content-Type': 'application/json', 'if-match': response.headers.get('etag')}, body: JSON.stringify(current)});
      await write.text();
      if (write.status === 200) return true;
      assert.equal(write.status, 412);
    }
    throw new Error('Contention did not settle');
  }
  const results = await Promise.all(['alice', 'bob'].map(reserve));
  assert.equal(results.filter(Boolean).length, 1);
});
