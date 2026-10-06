// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';
import {initializeApp, deleteApp} from 'firebase/app';
import {getAuth, connectAuthEmulator, signInAnonymously} from 'firebase/auth';
import {getFunctions, connectFunctionsEmulator, httpsCallable} from 'firebase/functions';
import {getDatabase, connectDatabaseEmulator, ref, get, goOffline} from 'firebase/database';
import {initializeApp as initializeAdminApp, deleteApp as deleteAdminApp} from 'firebase-admin/app';
import {getDatabase as getAdminDatabase} from 'firebase-admin/database';

const projectId = 'demo-familyhelper';
test('grandma can withdraw photo consent even without a configured Storage bucket', async () => {
  const authHost = process.env.FIREBASE_AUTH_EMULATOR_HOST;
  const dbHost = process.env.FIREBASE_DATABASE_EMULATOR_HOST;
  const functionsHost = process.env.FIREBASE_FUNCTIONS_EMULATOR_HOST || '127.0.0.1:5001';
  for (const value of [authHost, dbHost, functionsHost]) {
    if (!value || !/^(localhost|127\.0\.0\.1):\d+$/.test(value)) throw new Error('Local Firebase emulators required');
  }
  const app = initializeApp({
    projectId, apiKey: 'emulator-only', appId: 'consent-no-storage',
    databaseURL: `https://${projectId}-default-rtdb.asia-southeast1.firebasedatabase.app`,
  }, 'consent-no-storage');
  const auth = getAuth(app);
  connectAuthEmulator(auth, `http://${authHost}`, {disableWarnings: true});
  const functions = getFunctions(app, 'asia-east1');
  const [fh, fp] = functionsHost.split(':');
  connectFunctionsEmulator(functions, fh, Number(fp));
  const database = getDatabase(app);
  const [dh, dp] = dbHost.split(':');
  connectDatabaseEmulator(database, dh, Number(dp));
  const call = async (name, data = {}) => (await httpsCallable(functions, name)(data)).data;
  const admin = initializeAdminApp({
    projectId, databaseURL: `https://${projectId}-default-rtdb.asia-southeast1.firebasedatabase.app`,
  }, 'photo-consent-seed');
  try {
    await signInAnonymously(auth);
    await call('registerDevice', {role: 'host', name: '長輩'});
    await assert.rejects(call('setPhotoConsent', {enabled: true}), {code: 'functions/failed-precondition'});
    await getAdminDatabase(admin).ref(`core/families/${auth.currentUser.uid}/photoConsent`).set({
      enabled: true, version: 1, shareGeneration: 1, updatedAt: Date.now(),
    });
    await call('setPhotoConsent', {enabled: false});
    await call('revokePhotoConsent');
    const consent = (await get(ref(database, `core/families/${auth.currentUser.uid}/photoConsent`))).val();
    assert.equal(consent.enabled, false);
    assert.ok(consent.revokedAt);
  } finally {
    goOffline(database);
    await Promise.all([deleteApp(app), deleteAdminApp(admin)]);
  }
});
