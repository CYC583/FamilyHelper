// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';
import sharp from 'sharp';
import * as model from '../src/state.js';
import {createPhotoGateway, runPhotoCleanup} from '../src/photo_gateway.js';

const start = Date.UTC(2026, 9, 2, 10);
async function photoBase64() {
  return (await sharp({create: {width: 120, height: 120, channels: 3, background: '#749c84'}})
    .jpeg().toBuffer()).toString('base64');
}

function fixture() {
  let state = {};
  let clock = start;
  let nextId = 0;
  const objects = new Map();
  let failSave = false;
  let failDelete = false;
  let beforeSave = null;
  let afterSave = null;
  let afterDownload = null;
  model.register(state, 'grandma', 'host', '長輩', start);
  for (const uid of ['alice', 'bob', 'outsider']) model.register(state, uid, 'client', uid, start);
  for (const uid of ['alice', 'bob']) {
    model.issueCode(state, 'grandma', uid, start);
    model.bind(state, uid, uid, start + 1);
  }
  const bucket = {
    file(path) {
      return {
        async save(bytes, options) {
          if (failSave) throw new Error('storage unavailable');
          if (beforeSave) await beforeSave();
          assert.equal(options.preconditionOpts.ifGenerationMatch, 0);
          assert.equal(options.metadata.contentType, 'image/jpeg');
          if (objects.has(path)) throw Object.assign(new Error('object exists'), {code: 412});
          objects.set(path, Buffer.from(bytes));
          if (afterSave) await afterSave();
        },
        async download() {
          if (!objects.has(path)) throw Object.assign(new Error('missing object'), {code: 404});
          if (afterDownload) await afterDownload();
          return [Buffer.from(objects.get(path))];
        },
        async delete() {
          if (failDelete) throw new Error('storage unavailable');
          if (!objects.delete(path)) throw Object.assign(new Error('missing object'), {code: 404});
        },
      };
    },
  };
  const gateway = createPhotoGateway({
    readCore: async () => structuredClone(state),
    atomic: async update => {
      const next = structuredClone(state);
      update(next);
      state = next;
      return structuredClone(state);
    },
    bucket,
    now: () => clock,
    newId: () => `media-${++nextId}`,
  });
  return {
    gateway, objects,
    state: () => state,
    advance: ms => { clock += ms; },
    failSave: value => { failSave = value; },
    failDelete: value => { failDelete = value; },
    beforeSave: callback => { beforeSave = callback; },
    afterSave: callback => { afterSave = callback; },
    afterDownload: callback => { afterDownload = callback; },
    unpair: uid => { model.revoke(state, 'grandma', 'grandma', uid, clock); },
    mutateState: update => { update(state); },
  };
}

test('photo appears only after a private object exists and caller remains authorized', async () => {
  const f = fixture();
  const jpegBase64 = await photoBase64();
  await assert.rejects(f.gateway.upload('alice', {hostId: 'grandma', opId: 'a1', jpegBase64}), {code: 'failed-precondition'});
  await f.gateway.setConsent('grandma', true);
  const uploaded = await f.gateway.upload('alice', {hostId: 'grandma', opId: 'a1', jpegBase64});
  assert.deepEqual(Object.keys(uploaded).sort(), ['createdAt', 'day', 'mediaId']);
  assert.equal(f.objects.size, 1);
  assert.equal(f.state().photoOps.grandma.a1.status, 'ready');
  const listing = await f.gateway.list('bob', {hostId: 'grandma'});
  assert.deepEqual(listing, [{mediaId: uploaded.mediaId, authorId: 'alice', day: '2026-10-02', createdAt: start}]);
  const downloaded = await f.gateway.get('bob', {hostId: 'grandma', mediaId: uploaded.mediaId});
  assert.equal(downloaded.jpegBase64, f.objects.values().next().value.toString('base64'));
  assert.equal(JSON.stringify({uploaded, listing, downloaded}).includes('care-photos/'), false);
  await assert.rejects(f.gateway.get('outsider', {hostId: 'grandma', mediaId: uploaded.mediaId}), {code: 'permission-denied'});
});

test('same operation retries safely; changed bytes and duplicate object cannot publish a second photo', async () => {
  const f = fixture(); await f.gateway.setConsent('grandma', true);
  const jpegBase64 = await photoBase64();
  const first = await f.gateway.upload('alice', {hostId: 'grandma', opId: 'a1', jpegBase64});
  assert.deepEqual(await f.gateway.upload('alice', {hostId: 'grandma', opId: 'a1', jpegBase64}), first);
  assert.equal(f.objects.size, 1);
  const different = (await sharp({create: {width: 120, height: 120, channels: 3, background: '#284b37'}}).jpeg().toBuffer()).toString('base64');
  await assert.rejects(f.gateway.upload('alice', {hostId: 'grandma', opId: 'a1', jpegBase64: different}), {code: 'already-exists'});
  assert.equal(f.objects.size, 1);
});

test('failed object save never publishes ready; retry of the same operation succeeds', async () => {
  const f = fixture(); await f.gateway.setConsent('grandma', true);
  const jpegBase64 = await photoBase64();
  f.failSave(true);
  await assert.rejects(f.gateway.upload('alice', {hostId: 'grandma', opId: 'a1', jpegBase64}));
  assert.equal(f.state().photoOps.grandma.a1.status, 'pending');
  assert.deepEqual(await f.gateway.list('alice', {hostId: 'grandma'}), []);
  f.failSave(false);
  const result = await f.gateway.upload('alice', {hostId: 'grandma', opId: 'a1', jpegBase64});
  assert.equal(f.state().photoOps.grandma.a1.status, 'ready');
  assert.equal((await f.gateway.list('alice', {hostId: 'grandma'}))[0].mediaId, result.mediaId);
});

test('pause and unpair deny reads; revoke selects private object for deletion', async () => {
  const f = fixture(); await f.gateway.setConsent('grandma', true);
  const uploaded = await f.gateway.upload('alice', {hostId: 'grandma', opId: 'a1', jpegBase64: await photoBase64()});
  await f.gateway.setConsent('grandma', false);
  await assert.rejects(f.gateway.get('bob', {hostId: 'grandma', mediaId: uploaded.mediaId}), {code: 'failed-precondition'});
  assert.equal(f.objects.size, 1);
  await f.gateway.setConsent('grandma', true);
  assert.ok((await f.gateway.get('bob', {hostId: 'grandma', mediaId: uploaded.mediaId})).jpegBase64);
  f.unpair('alice');
  await assert.rejects(f.gateway.get('bob', {hostId: 'grandma', mediaId: uploaded.mediaId}), {code: 'not-found'});
  assert.deepEqual(await f.gateway.list('bob', {hostId: 'grandma'}), []);
  await f.gateway.cleanup();
  assert.equal(f.objects.size, 0);
  assert.equal(f.state().photoOps.grandma.a1, undefined);
});

test('Storage deletion failure retains metadata for a later cleanup retry', async () => {
  const f = fixture(); await f.gateway.setConsent('grandma', true);
  const uploaded = await f.gateway.upload('grandma', {hostId: 'grandma', opId: 'g1', jpegBase64: await photoBase64()});
  await f.gateway.revokeConsent('grandma');
  await assert.rejects(f.gateway.get('grandma', {hostId: 'grandma', mediaId: uploaded.mediaId}), {code: 'failed-precondition'});
  f.failDelete(true);
  const failed = await f.gateway.cleanup();
  assert.equal(failed.failed, 1);
  assert.equal(f.objects.size, 1);
  assert.ok(f.state().photoOps.grandma.g1);
  f.failDelete(false);
  const recovered = await f.gateway.cleanup();
  assert.equal(recovered.deleted, 1);
  assert.equal(f.objects.size, 0);
  assert.equal(f.state().photoOps.grandma.g1, undefined);
});

test('unpaired upload is denied before rate accounting or image decoding work', async () => {
  const f = fixture(); await f.gateway.setConsent('grandma', true);
  await assert.rejects(f.gateway.upload('outsider', {
    hostId: 'grandma', opId: 'x1', jpegBase64: await photoBase64(),
  }), {code: 'permission-denied'});
  assert.equal(f.state().rates?.photo_upload_outsider, undefined);
});

test('revoke during object save prevents publication and cleanup deletes the orphan', async () => {
  const f = fixture(); await f.gateway.setConsent('grandma', true);
  f.afterSave(() => f.gateway.revokeConsent('grandma'));
  await assert.rejects(f.gateway.upload('alice', {
    hostId: 'grandma', opId: 'a1', jpegBase64: await photoBase64(),
  }), {code: 'failed-precondition'});
  assert.equal(f.state().photoOps.grandma.a1.status, 'pending');
  assert.equal(f.objects.size, 1);
  f.advance(10 * 60_000 + 1);
  const result = await f.gateway.cleanup();
  assert.equal(result.deleted, 1);
  assert.equal(f.objects.size, 0);
});

test('unpair during download prevents returning bytes from a stale auth snapshot', async () => {
  const f = fixture(); await f.gateway.setConsent('grandma', true);
  const uploaded = await f.gateway.upload('grandma', {
    hostId: 'grandma', opId: 'g1', jpegBase64: await photoBase64(),
  });
  f.afterDownload(() => f.unpair('bob'));
  await assert.rejects(f.gateway.get('bob', {hostId: 'grandma', mediaId: uploaded.mediaId}), {code: 'permission-denied'});
});

test('download refuses corrupted private objects', async () => {
  const f = fixture(); await f.gateway.setConsent('grandma', true);
  const uploaded = await f.gateway.upload('grandma', {
    hostId: 'grandma', opId: 'g1', jpegBase64: await photoBase64(),
  });
  const path = f.state().photoOps.grandma.g1.objectPath;
  f.objects.set(path, Buffer.from('corrupted'));
  await assert.rejects(f.gateway.get('grandma', {hostId: 'grandma', mediaId: uploaded.mediaId}), {code: 'data-loss'});
});

test('private photo downloads are rate-limited before Storage reads', async () => {
  const f = fixture(); await f.gateway.setConsent('grandma', true);
  const uploaded = await f.gateway.upload('grandma', {
    hostId: 'grandma', opId: 'g1', jpegBase64: await photoBase64(),
  });
  for (let i = 0; i < 60; i++) {
    await f.gateway.get('bob', {hostId: 'grandma', mediaId: uploaded.mediaId});
  }
  await assert.rejects(f.gateway.get('bob', {hostId: 'grandma', mediaId: uploaded.mediaId}), {code: 'resource-exhausted'});
});

test('cleanup reports candidates left after its bounded batch', async () => {
  const f = fixture(); await f.gateway.setConsent('grandma', true);
  f.mutateState(s => {
    s.photoOps = {grandma: {}};
    for (let i = 0; i < 101; i++) {
      s.photoOps.grandma[`expired-${i}`] = {
        mediaId: `media-${i}`, objectPath: `care-photos/grandma/media-${i}.jpg`,
        status: 'ready', expiresAt: start - 1,
      };
    }
  });
  const result = await f.gateway.cleanup();
  assert.deepEqual(result, {deleted: 100, failed: 0, pending: 1});
  assert.equal(Object.keys(f.state().photoOps.grandma).length, 1);
});

test('revoked in-flight upload cannot write an orphan after cleanup forgets metadata', async () => {
  const f = fixture(); await f.gateway.setConsent('grandma', true);
  let enteredSave;
  let resumeSave;
  const saveEntered = new Promise(resolve => { enteredSave = resolve; });
  const saveResume = new Promise(resolve => { resumeSave = resolve; });
  f.beforeSave(async () => { enteredSave(); await saveResume; });
  const upload = f.gateway.upload('alice', {
    hostId: 'grandma', opId: 'a1', jpegBase64: await photoBase64(),
  });
  await saveEntered;
  await f.gateway.revokeConsent('grandma');
  const early = await f.gateway.cleanup();
  assert.equal(early.deleted, 0);
  assert.ok(f.state().photoOps.grandma.a1);
  resumeSave();
  await assert.rejects(upload, {code: 'failed-precondition'});
  f.advance(10 * 60_000 + 1);
  const late = await f.gateway.cleanup();
  assert.equal(late.deleted, 1);
  assert.equal(f.objects.size, 0);
  assert.equal(f.state().photoOps.grandma.a1, undefined);
});

test('scheduled photo cleanup surfaces deletion failures without logging private paths', async () => {
  const f = fixture(); await f.gateway.setConsent('grandma', true);
  await f.gateway.upload('grandma', {
    hostId: 'grandma', opId: 'g1', jpegBase64: await photoBase64(),
  });
  await f.gateway.revokeConsent('grandma');
  f.failDelete(true);
  const logs = [];
  await assert.rejects(runPhotoCleanup(f.gateway, result => logs.push(result)), /cleanup incomplete/);
  assert.deepEqual(logs, [{deleted: 0, failed: 1, pending: 1}]);
  assert.equal(JSON.stringify(logs).includes('care-photos/'), false);
  assert.equal(f.objects.size, 1);
});

test('photo list is bounded per member and photo downloads have a family 30-day guard', async () => {
  const f = fixture(); await f.gateway.setConsent('grandma', true);
  const uploaded = await f.gateway.upload('grandma', {
    hostId: 'grandma', opId: 'g1', jpegBase64: await photoBase64(),
  });
  for (let i = 0; i < 30; i++) await f.gateway.list('bob', {hostId: 'grandma'});
  await assert.rejects(f.gateway.list('bob', {hostId: 'grandma'}), {code: 'resource-exhausted'});
  f.mutateState(s => {
    s.rates ??= {};
    s.rates.photo_download_family_grandma = {count: 1500, until: start + 30 * 24 * 60 * 60_000};
  });
  await assert.rejects(f.gateway.get('alice', {hostId: 'grandma', mediaId: uploaded.mediaId}),
    {code: 'resource-exhausted'});
});
