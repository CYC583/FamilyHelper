// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';
import {initializeApp, deleteApp} from 'firebase/app';
import {getAuth, connectAuthEmulator, signInAnonymously} from 'firebase/auth';
import {getFunctions, connectFunctionsEmulator, httpsCallable} from 'firebase/functions';
import {initializeApp as adminApp, deleteApp as deleteAdminApp} from 'firebase-admin/app';
import {getDatabase as adminDatabase} from 'firebase-admin/database';

const projectId = 'demo-familyhelper';
const authHost = process.env.FIREBASE_AUTH_EMULATOR_HOST;
const dbHost = process.env.FIREBASE_DATABASE_EMULATOR_HOST;
const functionsHost = process.env.FIREBASE_FUNCTIONS_EMULATOR_HOST || '127.0.0.1:5001';
for (const address of [authHost, dbHost, functionsHost]) {
  if (!address || !/^(localhost|127\.0\.0\.1):\d+$/.test(address)) {
    throw new Error('Battery callable tests require local Firebase emulators');
  }
}

async function device(name) {
  const app = initializeApp({projectId, apiKey: 'emulator-only', appId: `battery-${name}`}, `battery-${name}`);
  const auth = getAuth(app);
  connectAuthEmulator(auth, `http://${authHost}`, {disableWarnings: true});
  const functions = getFunctions(app, 'asia-east1');
  const [host, port] = functionsHost.split(':');
  connectFunctionsEmulator(functions, host, Number(port));
  await signInAnonymously(auth);
  return {
    app, uid: auth.currentUser.uid,
    call: async (name, data = {}) => (await httpsCallable(functions, name)(data)).data,
  };
}

function low(seq, percent, base, elapsed) {
  return {
    batteryPercent: percent, charging: false, observedAt: base + elapsed,
    episodeId: 'emulator-episode-1', sampleSeq: seq, phase: 'low',
    severity: percent <= 15 ? 'critical' : 'low',
    lowEvidence: {bootEpoch: 'emulator-boot-1', firstMonotonicMs: 1000,
      currentMonotonicMs: 1000 + elapsed, firstSampleSeq: 1, currentSampleSeq: seq},
  };
}

test('anonymous callables serialize consent, one event, member ack, unpair and revoke', async () => {
  const devices = [];
  let admin;
  try {
    const unauthenticated = await fetch(`http://${functionsHost}/${projectId}/asia-east1/setBatteryConsent`, {
      method: 'POST', headers: {'content-type': 'application/json'},
      body: JSON.stringify({data: {enabled: true, expectedVersion: 0}}),
    });
    assert.equal(unauthenticated.status, 401);
    const host = await device('host'); devices.push(host);
    const alice = await device('alice'); devices.push(alice);
    const bob = await device('bob'); devices.push(bob);
    const outsider = await device('outsider'); devices.push(outsider);
    await host.call('registerDevice', {role: 'host', name: '長輩'});
    for (const client of [alice, bob, outsider]) {
      await client.call('registerDevice', {role: 'client', name: '家人'});
    }
    for (const client of [alice, bob]) {
      const {code} = await host.call('createPairCode');
      await client.call('pairDevice', {code});
    }
    admin = adminApp({projectId,
      databaseURL: `https://${projectId}-default-rtdb.asia-southeast1.firebasedatabase.app`,
    }, 'battery-admin');
    const db = adminDatabase(admin);
    const path = `care/${host.uid}/battery`;
    const base = Date.now() - 31 * 60_000;
    await assert.rejects(alice.call('setBatteryConsent', {enabled: true, expectedVersion: 0}),
      {code: 'functions/permission-denied'});
    await assert.rejects(host.call('reportBatterySample', {
      sample: low(1, 30, base, 0), consentVersion: 1,
    }), {code: 'functions/failed-precondition'});
    const consent = await host.call('setBatteryConsent',
      {enabled: true, expectedVersion: 0, disclosureVersion: 2});
    assert.equal(consent.version, 1);
    await assert.rejects(host.call('setBatteryConsent', {enabled: false, expectedVersion: 0}),
      {code: 'functions/failed-precondition'});
    const first = await host.call('reportBatterySample', {sample: low(1, 30, base, 0), consentVersion: 1});
    assert.equal(first.eventId, null);
    const second = low(2, 29, base, 31 * 60_000);
    const concurrent = await Promise.allSettled([
      host.call('reportBatterySample', {sample: second, consentVersion: 1}),
      host.call('reportBatterySample', {sample: second, consentVersion: 1}),
    ]);
    assert.equal(concurrent.filter(result => result.status === 'fulfilled').length, 2);
    const battery = (await db.ref(path).get()).val();
    assert.equal(Object.keys(battery.events).length, 1);
    assert.equal(battery.events['emulator-episode-1'].severity, 'low');
    assert.equal(battery.pushOps['emulator-episode-1'][alice.uid].attempts, 1);
    assert.equal(battery.pushOps['emulator-episode-1'][bob.uid].attempts, 1);
    await assert.rejects(outsider.call('ackBatteryEvent', {
      hostId: host.uid, eventId: 'emulator-episode-1',
    }), {code: 'functions/permission-denied'});
    await alice.call('ackBatteryEvent', {hostId: host.uid, eventId: 'emulator-episode-1'});
    assert.ok((await db.ref(`${path}/events/emulator-episode-1/acknowledgedAt/${alice.uid}`).get()).val());
    await host.call('unpairDevice', {hostId: host.uid, clientId: alice.uid});
    await assert.rejects(alice.call('ackBatteryEvent', {
      hostId: host.uid, eventId: 'emulator-episode-1',
    }), {code: 'functions/permission-denied'});
    await host.call('setBatteryConsent', {enabled: false, expectedVersion: 1, revoke: true});
    assert.equal((await db.ref(`${path}/latest`).get()).val(), null);
    assert.equal((await db.ref(`${path}/events`).get()).val(), null);
    await assert.rejects(host.call('reportBatterySample', {
      sample: low(3, 29, base, 32 * 60_000), consentVersion: 1,
    }), {code: 'functions/failed-precondition'});
  } finally {
    await Promise.all(devices.map(({app}) => deleteApp(app)));
    if (admin) await deleteAdminApp(admin);
  }
});
