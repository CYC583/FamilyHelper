// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';
import {initializeApp, deleteApp} from 'firebase/app';
import {getAuth, connectAuthEmulator, signInAnonymously} from 'firebase/auth';
import {getFunctions, connectFunctionsEmulator, httpsCallable} from 'firebase/functions';
import {getDatabase, connectDatabaseEmulator, ref, get, goOffline} from 'firebase/database';

const projectId = 'demo-familyhelper';
const authHost = process.env.FIREBASE_AUTH_EMULATOR_HOST;
const functionsHost = process.env.FIREBASE_FUNCTIONS_EMULATOR_HOST || '127.0.0.1:5001';
async function device(name) {
  const app = initializeApp({projectId, apiKey: 'emulator-only', appId: `ring-${name}`,
    databaseURL: `https://${projectId}-default-rtdb.asia-southeast1.firebasedatabase.app`}, `ring-${name}`);
  const auth = getAuth(app);
  connectAuthEmulator(auth, `http://${authHost}`, {disableWarnings: true});
  const functions = getFunctions(app, 'asia-east1');
  const [h, p] = functionsHost.split(':');
  connectFunctionsEmulator(functions, h, Number(p));
  await signInAnonymously(auth);
  const database = getDatabase(app);
  const dbHost = process.env.FIREBASE_DATABASE_EMULATOR_HOST;
  if (dbHost) connectDatabaseEmulator(database, dbHost.split(':')[0], Number(dbHost.split(':')[1]));
  return {app, uid: auth.currentUser.uid, database,
    call: async (fn, data = {}) => (await httpsCallable(functions, fn)(data)).data};
}

test('grandma SOS rings family; first answer wins; old clients without withCall still get alert only', async () => {
  const all = [];
  try {
    const host = await device('host'); all.push(host);
    const alice = await device('alice'); all.push(alice);
    const bob = await device('bob'); all.push(bob);
    await host.call('registerDevice', {role: 'host', name: '長輩'});
    for (const c of [alice, bob]) {
      await c.call('registerDevice', {role: 'client', name: '家人'});
      const {code} = await host.call('createPairCode');
      await c.call('pairDevice', {code});
    }
    const legacy = await host.call('sendAlert', {type: 'call'});
    assert.equal(legacy.sessionId, null);
    const sos = await host.call('sendAlert', {type: 'sos', withCall: true});
    assert.ok(sos.sessionId);
    const answered = await bob.call('answerHostCall', {sessionId: sos.sessionId});
    assert.equal(answered.shareScreen, false);
    await assert.rejects(alice.call('answerHostCall', {sessionId: sos.sessionId}), {code: 'functions/failed-precondition'});
    await bob.call('heartbeat', {sessionId: sos.sessionId});
    await host.call('heartbeat', {sessionId: sos.sessionId});
    await host.call('endHelp', {sessionId: sos.sessionId});
    const call = await host.call('sendAlert', {type: 'call', withCall: true});
    const got = await alice.call('answerHostCall', {sessionId: call.sessionId});
    assert.equal(got.shareScreen, true);
    await assert.rejects(host.call('reportPlaceEvent', {place: 'home', transition: 'exit', at: Date.now(), consentVersion: 1}),
      {code: 'functions/failed-precondition'});
    const consent = await host.call('setPlaceAlerts', {enabled: true, disclosureVersion: 1, homeSet: true});
    const first = await host.call('reportPlaceEvent', {place: 'home', transition: 'exit', at: Date.now(), consentVersion: consent.version});
    assert.equal(first.ok, true);
    const again = await host.call('reportPlaceEvent', {place: 'home', transition: 'exit', at: Date.now(), consentVersion: consent.version});
    assert.equal(again.duplicate, true);
    await assert.rejects(alice.call('setPlaceAlerts', {enabled: true, disclosureVersion: 1}), {code: 'functions/permission-denied'});
    // Ring grandma's phone: needs her location consent, then a message from
    // the person who pressed it lets her phone say who is looking for her.
    await assert.rejects(alice.call('ringHostPhone', {hostId: host.uid}), {code: 'functions/failed-precondition'});
    await host.call('setLocationSharing', {enabled: true, disclosureVersion: 1});
    const rang = await alice.call('ringHostPhone', {hostId: host.uid});
    assert.equal(rang.ok, true);
    assert.equal(rang.announced, true);
    const items = Object.values((await get(ref(host.database, `care/${host.uid}/messages/items`))).val() || {});
    assert.equal(items.find(m => m.authorId === alice.uid)?.text, '我按了讓你的手機響，看到請回我');
    await assert.rejects(alice.call('ringHostPhone', {hostId: host.uid}), {code: 'functions/resource-exhausted'});
  } finally { all.forEach(d => goOffline(d.database)); await Promise.all(all.map(d => deleteApp(d.app))); }
});

