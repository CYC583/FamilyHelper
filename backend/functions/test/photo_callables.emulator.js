// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';
import sharp from 'sharp';
import {initializeApp, deleteApp} from 'firebase/app';
import {getAuth, connectAuthEmulator, signInAnonymously} from 'firebase/auth';
import {getFunctions, connectFunctionsEmulator, httpsCallable} from 'firebase/functions';
import {getStorage, connectStorageEmulator, ref as storageRef, uploadBytes, getDownloadURL} from 'firebase/storage';
import {initializeApp as initializeAdminApp, deleteApp as deleteAdminApp} from 'firebase-admin/app';
import {getDatabase as getAdminDatabase} from 'firebase-admin/database';

const projectId = 'demo-familyhelper';
const storageBucket = `${projectId}.firebasestorage.app`;
const addresses = {
  auth: process.env.FIREBASE_AUTH_EMULATOR_HOST,
  functions: process.env.FIREBASE_FUNCTIONS_EMULATOR_HOST || '127.0.0.1:5001',
  storage: process.env.FIREBASE_STORAGE_EMULATOR_HOST,
};
for (const value of Object.values(addresses)) {
  if (!value || !/^(localhost|127\.0\.0\.1):\d+$/.test(value)) {
    throw new Error('Photo integration tests require local Auth, Functions and Storage emulators');
  }
}

async function device(name) {
  const app = initializeApp({
    projectId, apiKey: 'emulator-only', appId: `photo-${name}`, storageBucket,
  }, `photo-${name}`);
  const auth = getAuth(app);
  connectAuthEmulator(auth, `http://${addresses.auth}`, {disableWarnings: true});
  const functions = getFunctions(app, 'asia-east1');
  const [functionsHost, functionsPort] = addresses.functions.split(':');
  connectFunctionsEmulator(functions, functionsHost, Number(functionsPort));
  const storage = getStorage(app);
  const [storageHost, storagePort] = addresses.storage.split(':');
  connectStorageEmulator(storage, storageHost, Number(storagePort));
  await signInAnonymously(auth);
  return {
    app, storage, uid: auth.currentUser.uid,
    call: async (name, data = {}) => (await httpsCallable(functions, name)(data)).data,
  };
}

test('photo callables enforce private Storage and revocation across actual emulators', async () => {
  const devices = [];
  const admin = initializeAdminApp({
    projectId, databaseURL: `https://${projectId}-default-rtdb.asia-southeast1.firebasedatabase.app`,
  }, 'photo-gateway-test-reset');
  try {
    // This test can run after the existing callable suite in one emulator run.
    await getAdminDatabase(admin).ref().set(null);
    const grandma = await device('grandma'); devices.push(grandma);
    const alice = await device('alice'); devices.push(alice);
    const outsider = await device('outsider'); devices.push(outsider);
    await grandma.call('registerDevice', {role: 'host', name: '長輩'});
    await alice.call('registerDevice', {role: 'client', name: '家人'});
    await outsider.call('registerDevice', {role: 'client', name: '其他人'});
    const pair = await grandma.call('createPairCode');
    await alice.call('pairDevice', {code: pair.code});
    const jpegBase64 = (await sharp({create: {width: 120, height: 120, channels: 3, background: '#749c84'}})
      .jpeg().toBuffer()).toString('base64');
    const data = {hostId: grandma.uid, opId: 'photo-test-1', jpegBase64};

    await assert.rejects(alice.call('uploadCarePhoto', data), {code: 'functions/failed-precondition'});
    await assert.rejects(alice.call('setPhotoConsent', {enabled: true}), {code: 'functions/permission-denied'});
    await grandma.call('setPhotoConsent', {enabled: true});
    const uploaded = await alice.call('uploadCarePhoto', data);
    assert.match(uploaded.mediaId, /^[a-zA-Z0-9-]+$/);
    assert.deepEqual(Object.keys(uploaded).sort(), ['createdAt', 'day', 'mediaId']);
    assert.deepEqual(await alice.call('uploadCarePhoto', data), uploaded);
    const listing = await grandma.call('listCarePhotos', {hostId: grandma.uid});
    assert.equal(listing.photos.length, 1);
    assert.equal(listing.photos[0].mediaId, uploaded.mediaId);
    const photo = await grandma.call('getCarePhoto', {hostId: grandma.uid, mediaId: uploaded.mediaId});
    assert.ok(Buffer.from(photo.jpegBase64, 'base64').length > 0);
    await assert.rejects(outsider.call('getCarePhoto', {hostId: grandma.uid, mediaId: uploaded.mediaId}),
      {code: 'functions/permission-denied'});

    const object = storageRef(alice.storage, `care-photos/${grandma.uid}/${uploaded.mediaId}.jpg`);
    await assert.rejects(uploadBytes(object, Buffer.from(jpegBase64, 'base64')), {code: 'storage/unauthorized'});
    await assert.rejects(getDownloadURL(object), {code: 'storage/unauthorized'});
    await grandma.call('revokePhotoConsent');
    await assert.rejects(grandma.call('getCarePhoto', {hostId: grandma.uid, mediaId: uploaded.mediaId}),
      {code: 'functions/failed-precondition'});
  } finally {
    await Promise.all([...devices.map(({app}) => deleteApp(app)), deleteAdminApp(admin)]);
  }
});
