// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';
import {initializeApp, deleteApp} from 'firebase/app';
import {getAuth, connectAuthEmulator, signInAnonymously} from 'firebase/auth';
import {getFunctions, connectFunctionsEmulator, httpsCallable} from 'firebase/functions';
import {getDatabase, connectDatabaseEmulator, ref, get} from 'firebase/database';
import {initializeApp as adminApp, deleteApp as deleteAdminApp} from 'firebase-admin/app';
import {getDatabase as adminDatabase} from 'firebase-admin/database';

const projectId = 'demo-familyhelper';
const authHost = process.env.FIREBASE_AUTH_EMULATOR_HOST;
const dbHost = process.env.FIREBASE_DATABASE_EMULATOR_HOST;
const functionsHost = process.env.FIREBASE_FUNCTIONS_EMULATOR_HOST || '127.0.0.1:5001';
for (const address of [authHost, dbHost, functionsHost, process.env.FIREBASE_STORAGE_EMULATOR_HOST]) {
  if (!address || !/^(localhost|127\.0\.0\.1):\d+$/.test(address)) {
    throw new Error('Companion callable tests require local Firebase emulators');
  }
}
const databaseURL = `https://${projectId}-default-rtdb.asia-southeast1.firebasedatabase.app`;
const m4a = Buffer.concat([Buffer.from([0, 0, 0, 24]), Buffer.from('ftypM4A '), Buffer.alloc(200, 7)]);

async function device(name) {
  const app = initializeApp({projectId, apiKey: 'emulator-only', appId: `care-${name}`, databaseURL}, `care-${name}`);
  const auth = getAuth(app);
  connectAuthEmulator(auth, `http://${authHost}`, {disableWarnings: true});
  const functions = getFunctions(app, 'asia-east1');
  const [host, port] = functionsHost.split(':');
  connectFunctionsEmulator(functions, host, Number(port));
  const database = getDatabase(app);
  const [dbh, dbp] = dbHost.split(':');
  connectDatabaseEmulator(database, dbh, Number(dbp));
  await signInAnonymously(auth);
  return {app, uid: auth.currentUser.uid, read: async path => (await get(ref(database, path))).val(),
    call: async (fn, data = {}) => (await httpsCallable(functions, fn)(data)).data};
}

test('companion consent, replies, messages, voice and unpair work end to end on emulators', async () => {
  const devices = [];
  try {
    const host = await device('host'); devices.push(host);
    const alice = await device('alice'); devices.push(alice);
    const bob = await device('bob'); devices.push(bob);
    await host.call('registerDevice', {role: 'host', name: '長輩'});
    for (const client of [alice, bob]) {
      await client.call('registerDevice', {role: 'client', name: '家人'});
      const {code} = await host.call('createPairCode');
      await client.call('pairDevice', {code});
    }
    const today = new Date(Date.now() + 8 * 3600_000).toISOString().slice(0, 10);
    await assert.rejects(alice.call('setCompanionConsent', {action: 'enable', items: {responses: true}, disclosureVersion: 1}),
      {code: 'functions/permission-denied'});
    await assert.rejects(host.call('recordReminderResponse', {date: today, type: 'medicine', time: '08:00',
      response: 'done', consentVersion: 1}), {code: 'functions/failed-precondition'});
    const consent = await host.call('setCompanionConsent', {action: 'enable',
      items: {responses: true, mood: true, sound: false}, disclosureVersion: 1});
    await host.call('recordReminderResponse', {date: today, type: 'medicine', time: '08:00',
      response: 'done', consentVersion: consent.version});
    await host.call('recordMood', {date: today, mood: 'good', consentVersion: consent.version});
    const replies = await alice.read(`care/${host.uid}/companion/responses/${today}`);
    assert.equal(replies.medicine_0800.response, 'done');
    assert.equal((await bob.read(`care/${host.uid}/companion/mood/${today}`)).mood, 'good');

    const text = await alice.call('sendCareMessage', {hostId: host.uid, kind: 'text', text: '長輩早安'});
    const voice = await bob.call('sendCareMessage', {hostId: host.uid, kind: 'voice', durationMs: 4000,
      audioBase64: m4a.toString('base64')});
    const items = await host.read(`care/${host.uid}/messages/items`);
    assert.equal(items[text.id].text, '長輩早安');
    assert.equal(items[voice.id].status, 'ready');
    const played = await host.call('getVoiceMessage', {hostId: host.uid, id: voice.id});
    assert.equal(Buffer.from(played.audioBase64, 'base64').equals(m4a), true);

    // Photo hearts need a visible photo; seed the private ledger as the server would.
    const admin = adminApp({projectId, databaseURL}, 'care-admin');
    try {
      const db = adminDatabase(admin);
      await db.ref(`core/families/${host.uid}/photoConsent`).set({enabled: true, version: 1, shareGeneration: 1});
      await db.ref(`core/photoOps/${host.uid}/op1`).set({mediaId: 'm1', authorId: host.uid, status: 'ready',
        shareGeneration: 1, expiresAt: Date.now() + 3600_000, createdAt: Date.now(), day: today});
      await alice.call('reactToPhoto', {hostId: host.uid, mediaId: 'm1', heart: true, comment: '好可愛'});
      assert.equal((await bob.read(`care/${host.uid}/photoReactions/m1`))[alice.uid].comment, '好可愛');
      // Grandma's phone is told who reacted (it reads messages aloud).
      const notes = Object.values(await host.read(`care/${host.uid}/messages/items`));
      assert.ok(notes.some(m => m.authorId === alice.uid && m.text === '我在你的照片留言：好可愛'));
      await alice.call('reactToPhoto', {hostId: host.uid, mediaId: 'm1', heart: true, comment: '好可愛'});
      const again = Object.values(await host.read(`care/${host.uid}/messages/items`));
      assert.equal(again.filter(m => m.text?.startsWith('我在你的照片')).length, 1, 'no repeat for the same reaction');
      await assert.rejects(alice.call('reactToPhoto', {hostId: host.uid, mediaId: 'nope', heart: true}),
        {code: 'functions/not-found'});
      await db.ref(`core/families/${host.uid}/photoConsent/enabled`).set(false);
      await assert.rejects(bob.read(`care/${host.uid}/photoReactions/m1`));
    } finally { await deleteAdminApp(admin); }

    await host.call('setCompanionConsent', {action: 'pause'});
    await assert.rejects(alice.read(`care/${host.uid}/companion/responses/${today}`));
    await assert.rejects(host.call('recordMood', {date: today, mood: 'ok', consentVersion: consent.version}),
      {code: 'functions/failed-precondition'});

    await host.call('unpairDevice', {hostId: host.uid, clientId: bob.uid});
    await assert.rejects(bob.call('getVoiceMessage', {hostId: host.uid, id: voice.id}), {code: 'functions/permission-denied'});
    await assert.rejects(alice.call('getVoiceMessage', {hostId: host.uid, id: voice.id}), {code: 'functions/not-found'},
      'a removed author voice note is no longer playable by others');
    await assert.rejects(bob.read(`care/${host.uid}/messages/items`));
  } finally {
    await Promise.all(devices.map(d => deleteApp(d.app)));
  }
});
