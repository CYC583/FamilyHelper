// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';

async function resolver() {
  try {
    return (await import('../src/ice_servers.js')).resolveIceServers;
  } catch (error) {
    if (error.code === 'ERR_MODULE_NOT_FOUND') assert.fail('ICE resolver is missing');
    throw error;
  }
}

const base = {uid: 'family-uid', now: 1_790_812_800_000};
const cloudflare = {
  iceServers: [
    {urls: ['stun:stun.cloudflare.com:3478']},
    {urls: ['turn:turn.cloudflare.com:3478?transport=udp'], username: 'temporary', credential: 'short-lived'},
  ],
};

test('adds Cloudflare TURN only when both server-side key values are present', async () => {
  const resolveIceServers = await resolver();
  const result = await resolveIceServers({
    ...base, cloudflareKeyId: 'key-123', cloudflareToken: 'long-term-secret',
    fetchImpl: async () => new Response(JSON.stringify(cloudflare), {status: 201}),
  });
  assert.equal(result.hasTurn, true);
  assert.deepEqual(result.iceServers, [
    {urls: ['stun:stun.l.google.com:19302']}, ...cloudflare.iceServers,
  ]);
  assert.equal(JSON.stringify(result).includes('long-term-secret'), false);
});

test('Cloudflare failure falls back to STUN, never silently to old coturn', async () => {
  const resolveIceServers = await resolver();
  const result = await resolveIceServers({
    ...base, cloudflareKeyId: 'key-123', cloudflareToken: 'long-term-secret',
    turnUrl: 'turn:old.example:3478', turnSecret: 'old-secret',
    fetchImpl: async () => new Response('unavailable', {status: 503}),
  });
  assert.deepEqual(result, {iceServers: [{urls: ['stun:stun.l.google.com:19302']}], hasTurn: false});
});

test('partial Cloudflare configuration is STUN-only and does not fetch', async () => {
  const resolveIceServers = await resolver();
  let fetched = false;
  const result = await resolveIceServers({
    ...base, cloudflareKeyId: 'key-123', turnUrl: 'turn:old.example:3478', turnSecret: 'old-secret',
    fetchImpl: async () => { fetched = true; throw new Error('unexpected request'); },
  });
  assert.equal(fetched, false);
  assert.deepEqual(result, {iceServers: [{urls: ['stun:stun.l.google.com:19302']}], hasTurn: false});
});

test('the existing coturn path remains available when Cloudflare is not configured', async () => {
  const resolveIceServers = await resolver();
  const result = await resolveIceServers({
    ...base, turnUrl: 'turn:old.example:3478,turns:old.example:443', turnSecret: 'old-secret',
  });
  assert.equal(result.hasTurn, true);
  assert.deepEqual(result.iceServers[1].urls, ['turn:old.example:3478', 'turns:old.example:443']);
  assert.match(result.iceServers[1].username, /^\d+:family-uid$/);
  assert.ok(result.iceServers[1].credential);
  assert.equal(JSON.stringify(result).includes('old-secret'), false);
});

test('no TURN configuration returns only STUN with an explicit false flag', async () => {
  const resolveIceServers = await resolver();
  assert.deepEqual(await resolveIceServers(base), {
    iceServers: [{urls: ['stun:stun.l.google.com:19302']}], hasTurn: false,
  });
});

test('the setup wizard "disabled" placeholder never contacts Cloudflare', async () => {
  const resolveIceServers = await resolver();
  let fetched = false;
  const result = await resolveIceServers({
    ...base, cloudflareKeyId: 'disabled', cloudflareToken: 'disabled',
    fetchImpl: async () => { fetched = true; throw new Error('unexpected request'); },
  });
  assert.equal(fetched, false);
  assert.deepEqual(result, {iceServers: [{urls: ['stun:stun.l.google.com:19302']}], hasTurn: false});
});

test('"disabled" Cloudflare placeholders still allow the coturn path', async () => {
  const resolveIceServers = await resolver();
  const result = await resolveIceServers({
    ...base, cloudflareKeyId: 'disabled', cloudflareToken: 'disabled',
    turnUrl: 'turn:own.example:3478', turnSecret: 'own-secret',
  });
  assert.equal(result.hasTurn, true);
  assert.deepEqual(result.iceServers[1].urls, ['turn:own.example:3478']);
});
