// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';
import {initializeApp, deleteApp} from 'firebase/app';
import {getAuth, connectAuthEmulator, signInAnonymously} from 'firebase/auth';
import {getFunctions, connectFunctionsEmulator, httpsCallable} from 'firebase/functions';
import {getDatabase, connectDatabaseEmulator, ref, get} from 'firebase/database';

const projectId = 'demo-familyhelper';
const databaseURL = `https://${projectId}-default-rtdb.asia-southeast1.firebasedatabase.app`;
const m4a = Buffer.concat([Buffer.from([0, 0, 0, 24]), Buffer.from('ftypM4A '), Buffer.alloc(300, 5)]);
async function device(name) {
  const app = initializeApp({projectId, apiKey: 'emulator-only', appId: `plan-${name}`, databaseURL}, `plan-${name}`);
  const auth = getAuth(app);
  connectAuthEmulator(auth, `http://${process.env.FIREBASE_AUTH_EMULATOR_HOST}`, {disableWarnings: true});
  const functions = getFunctions(app, 'asia-east1');
  const [h, p] = (process.env.FIREBASE_FUNCTIONS_EMULATOR_HOST || '127.0.0.1:5001').split(':');
  connectFunctionsEmulator(functions, h, Number(p));
  const db = getDatabase(app);
  const [dh, dp] = process.env.FIREBASE_DATABASE_EMULATOR_HOST.split(':');
  connectDatabaseEmulator(db, dh, Number(dp));
  await signInAnonymously(auth);
  return {app, read: async path => (await get(ref(db, path))).val(),
    call: async (fn, data = {}) => (await httpsCallable(functions, fn)(data)).data, uid: auth.currentUser.uid};
}

test('family records a voice reminder; grandma reads the plan and downloads the voice', async () => {
  const all = [];
  try {
    const host = await device('host'); all.push(host);
    const alice = await device('alice'); all.push(alice);
    await host.call('registerDevice', {role: 'host', name: '長輩'});
    await alice.call('registerDevice', {role: 'client', name: '小明'});
    const {code} = await host.call('createPairCode');
    await alice.call('pairDevice', {code});
    const {voiceId} = await alice.call('uploadReminderVoice', {hostId: host.uid, audioBase64: m4a.toString('base64'), durationMs: 4000});
    const saved = await alice.call('setReminderPlan', {hostId: host.uid, expectedVersion: 0, items: [
      {type: 'custom', repeat: 'daily', time: '09:00', text: '', voiceId},
      {type: 'medicine', repeat: 'daily', time: '08:00', text: '吃血壓藥'},
    ]});
    assert.equal(saved.items.length, 2);
    const plan = await host.read(`care/${host.uid}/settings/reminderPlan`);
    assert.equal(plan.items.find(i => i.voiceId).author, '小明');
    const voice = await host.call('getReminderVoice', {hostId: host.uid, voiceId});
    assert.equal(Buffer.from(voice.audioBase64, 'base64').equals(m4a), true);
    await assert.rejects(host.call('setReminderPlan', {hostId: host.uid, expectedVersion: 1, items: []}),
      {code: 'functions/permission-denied'});
  } finally { await Promise.all(all.map(d => deleteApp(d.app))); }
});
