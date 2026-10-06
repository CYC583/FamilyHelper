// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';
import {initializeApp, deleteApp} from 'firebase/app';
import {getAuth, connectAuthEmulator, signInAnonymously} from 'firebase/auth';
import {getFunctions, connectFunctionsEmulator, httpsCallable} from 'firebase/functions';
import {getDatabase, connectDatabaseEmulator, goOffline, ref, get, set} from 'firebase/database';
import {initializeApp as initializeAdminApp, deleteApp as deleteAdminApp} from 'firebase-admin/app';
import {getDatabase as getAdminDatabase} from 'firebase-admin/database';

const projectId = 'demo-familyhelper';
const authHost = process.env.FIREBASE_AUTH_EMULATOR_HOST;
const dbHost = process.env.FIREBASE_DATABASE_EMULATOR_HOST;
const functionsHost = process.env.FIREBASE_FUNCTIONS_EMULATOR_HOST || '127.0.0.1:5001';
for (const address of [authHost, dbHost, functionsHost]) {
  if (!address || !/^(localhost|127\.0\.0\.1):\d+$/.test(address)) {
    throw new Error('Callable integration tests require local Firebase emulators');
  }
}

async function device(name) {
  const app = initializeApp({
    projectId,
    apiKey: 'emulator-only',
    appId: `emulator-${name}`,
    databaseURL: `https://${projectId}-default-rtdb.asia-southeast1.firebasedatabase.app`,
  }, name);
  const auth = getAuth(app);
  connectAuthEmulator(auth, `http://${authHost}`, {disableWarnings: true});
  const functions = getFunctions(app, 'asia-east1');
  connectFunctionsEmulator(functions, ...functionsHost.split(':').map((value, index) => index ? Number(value) : value));
  const database = getDatabase(app);
  connectDatabaseEmulator(database, ...dbHost.split(':').map((value, index) => index ? Number(value) : value));
  await signInAnonymously(auth);
  return {
    app,
    uid: auth.currentUser.uid,
    call: async (name, data = {}) => (await httpsCallable(functions, name)(data)).data,
    database,
  };
}

test('callables enforce pairing, consent, RTDB signals and termination together', async () => {
  const devices = [];
  const adminApps = [];
  try {
    const host = await device('grandma'); devices.push(host);
    const alice = await device('alice'); devices.push(alice);
    const bob = await device('bob'); devices.push(bob);
    const carol = await device('carol'); devices.push(carol);
    const dave = await device('dave'); devices.push(dave);
    const eve = await device('eve'); devices.push(eve);
    const frank = await device('frank'); devices.push(frank);
    const gina = await device('gina'); devices.push(gina);
    await Promise.all([
      host.call('registerDevice', {role: 'host', name: '長輩'}),
      alice.call('registerDevice', {role: 'client', name: 'Alice'}),
      bob.call('registerDevice', {role: 'client', name: 'Bob'}),
      carol.call('registerDevice', {role: 'client', name: 'Carol'}),
      dave.call('registerDevice', {role: 'client', name: 'Dave'}),
      eve.call('registerDevice', {role: 'client', name: 'Eve'}),
      frank.call('registerDevice', {role: 'client', name: 'Frank'}),
      gina.call('registerDevice', {role: 'client', name: 'Gina'}),
    ]);

    const first = await host.call('createPairCode');
    assert.match(first.code, /^\d{6}$/);
    assert.equal((await alice.call('pairDevice', {code: first.code})).hostId, host.uid);
    await assert.rejects(bob.call('pairDevice', {code: first.code}), {code: 'functions/not-found'});
    const second = await host.call('createPairCode');
    assert.equal((await bob.call('pairDevice', {code: second.code})).hostId, host.uid);
    const third = await host.call('createPairCode');
    assert.equal((await carol.call('pairDevice', {code: third.code})).hostId, host.uid);
    const fourth = await host.call('createPairCode');
    const race = await Promise.allSettled([
      dave.call('pairDevice', {code: fourth.code}),
      eve.call('pairDevice', {code: fourth.code}),
    ]);
    assert.equal(race.filter(result => result.status === 'fulfilled').length, 1);
    assert.equal(race.filter(result => result.status === 'rejected').length, 1);
    assert.equal(race.find(result => result.status === 'rejected').reason.code, 'functions/not-found');
    const winner = race[0].status === 'fulfilled' ? dave : eve;
    const loser = race[0].status === 'rejected' ? dave : eve;
    assert.equal((await get(ref(loser.database, `core/links/${loser.uid}`))).val(), null);
    const four = (await get(ref(host.database, `core/families/${host.uid}/members`))).val();
    assert.equal(Object.keys(four).length, 4);
    assert.ok(four[winner.uid]);
    // Fifth and sixth family phones still fit; a seventh code cannot be issued.
    for (const extra of [frank, gina]) {
      const code = await host.call('createPairCode');
      assert.equal((await extra.call('pairDevice', {code: code.code})).hostId, host.uid);
    }
    assert.equal(Object.keys((await get(ref(host.database, `core/families/${host.uid}/members`))).val()).length, 6);
    assert.ok((await get(ref(winner.database, `core/families/${host.uid}`))).exists());
    await assert.rejects(get(ref(loser.database, `core/families/${host.uid}`)), /Permission denied/);
    const weatherChoice = {hostId: host.uid, expectedVersion: 0,
      city: {name: '台北市', latitude: 25.05306, longitude: 121.52639}, morningTime: '08:30'};
    await assert.rejects(host.call('setWeatherSettings', weatherChoice), {code: 'functions/permission-denied'});
    await assert.rejects(loser.call('setWeatherSettings', weatherChoice), {code: 'functions/permission-denied'});
    const weather = await alice.call('setWeatherSettings', weatherChoice);
    assert.equal(weather.version, 1);
    assert.equal((await get(ref(host.database, `care/${host.uid}/settings/weather`))).val().morningTime, '08:30');
    assert.equal((await get(ref(bob.database, `care/${host.uid}/settings/weather`))).val().city.name, '台北市');
    await assert.rejects(bob.call('setWeatherSettings', weatherChoice), {code: 'functions/aborted'});
    await assert.rejects(get(ref(loser.database, `care/${host.uid}/settings/weather`)), /Permission denied/);
    const reminderChoice = {hostId: host.uid, expectedVersion: 0, items: [
      {type: 'water', time: '14:00', text: '喝點水'},
      {type: 'medicine', time: '08:00', text: ''},
    ]};
    await assert.rejects(host.call('setReminderSettings', reminderChoice), {code: 'functions/permission-denied'});
    await assert.rejects(loser.call('setReminderSettings', reminderChoice), {code: 'functions/permission-denied'});
    const reminders = await alice.call('setReminderSettings', reminderChoice);
    assert.equal(reminders.version, 1);
    assert.equal((await get(ref(host.database, `care/${host.uid}/settings/reminders`))).val().items[0].type, 'medicine');
    await assert.rejects(bob.call('setReminderSettings', reminderChoice), {code: 'functions/aborted'});
    await assert.rejects(get(ref(loser.database, `care/${host.uid}/settings/reminders`)), /Permission denied/);
    await assert.rejects(host.call('createPairCode'), {code: 'functions/resource-exhausted'});
    const alert = await host.call('sendAlert', {type: 'call'});
    assert.equal(alert.accepted, 0);
    assert.equal(alert.failed, 6);

    const {sessionId} = await alice.call('requestHelp', {hostId: host.uid});
    await assert.rejects(bob.call('requestHelp', {hostId: host.uid}), {code: 'functions/already-exists'});
    await assert.rejects(bob.call('getIceServers', {sessionId}), {code: 'functions/permission-denied'});
    await assert.rejects(alice.call('getIceServers', {sessionId}), {code: 'functions/failed-precondition'});
    await assert.rejects(alice.call('acceptHelp', {sessionId}), {code: 'functions/failed-precondition'});
    await host.call('acceptHelp', {sessionId});
    const ice = await alice.call('getIceServers', {sessionId});
    assert.equal(ice.hasTurn, true);
    assert.equal(ice.iceServers.length, 2);
    const family = (await get(ref(host.database, `core/families/${host.uid}`))).val();
    const liveSession = (await get(ref(host.database, `core/sessions/${sessionId}`))).val();
    assert.equal(family.activeSessionId, sessionId);
    assert.equal(liveSession.status, 'accepted');
    assert.ok(liveSession.leaseUntil > Date.now());
    const offer = ref(host.database, `signals/${sessionId}/offer`);
    await set(offer, {type: 'offer', sdp: 'v=0', screenStreamId: 'screen'});
    await assert.rejects(set(offer, {type: 'offer', sdp: 'v=1', screenStreamId: 'screen'}), /Permission denied/);
    assert.equal((await get(ref(alice.database, `signals/${sessionId}/offer`))).val().sdp, 'v=0');
    await assert.rejects(get(ref(bob.database, `signals/${sessionId}`)), /Permission denied/);
    await alice.call('endHelp', {sessionId});
    await assert.rejects(alice.call('getIceServers', {sessionId}), {code: 'functions/failed-precondition'});
    await assert.rejects(get(ref(alice.database, `signals/${sessionId}`)), /Permission denied/);
    await assert.rejects(host.call('acceptHelp', {sessionId}), {code: 'functions/failed-precondition'});

    await host.call('unpairDevice', {hostId: host.uid, clientId: bob.uid});
    await assert.rejects(get(ref(bob.database, `core/families/${host.uid}`)), /Permission denied/);
    const replacement = await host.call('createPairCode');
    assert.equal((await loser.call('pairDevice', {code: replacement.code})).hostId, host.uid);
    assert.equal(Object.keys((await get(ref(host.database, `core/families/${host.uid}/members`))).val()).length, 6);

    const expiring = await alice.call('requestHelp', {hostId: host.uid});
    await host.call('acceptHelp', {sessionId: expiring.sessionId});
    const admin = initializeAdminApp({
      projectId,
      databaseURL: `https://${projectId}-default-rtdb.asia-southeast1.firebasedatabase.app`,
    }, 'expired-session-test');
    adminApps.push(admin);
    await getAdminDatabase(admin).ref(`core/sessions/${expiring.sessionId}/expiresAt`).set(Date.now() - 1);
    await assert.rejects(alice.call('getIceServers', {sessionId: expiring.sessionId}), {
      code: 'functions/failed-precondition',
    });
  } finally {
    await Promise.all([
      ...devices.map(async ({app, database}) => {
        goOffline(database);
        await deleteApp(app);
      }),
      ...adminApps.map(deleteAdminApp),
    ]);
  }
});
