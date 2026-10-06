// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';

async function adapter() {
  try {
    return (await import('../src/cloudflare_turn.js')).fetchCloudflareIceServers;
  } catch (error) {
    if (error.code === 'ERR_MODULE_NOT_FOUND') assert.fail('TURN adapter is missing');
    throw error;
  }
}

const validIce = {
  iceServers: [
    {urls: ['stun:stun.cloudflare.com:3478']},
    {
      urls: [
        'turn:turn.cloudflare.com:3478?transport=udp',
        'turns:turn.cloudflare.com:443?transport=tcp',
      ],
      username: 'temporary-user',
      credential: 'temporary-password',
    },
  ],
};

test('requests 40-minute Cloudflare credentials and returns only validated ICE fields', async () => {
  const fetchCloudflareIceServers = await adapter();
  let request;
  const iceServers = await fetchCloudflareIceServers({
    keyId: 'key-123', apiToken: 'server-only-token',
    fetchImpl: async (url, options) => {
      request = {url, options};
      return new Response(JSON.stringify({...validIce, ignored: 'not-for-client'}), {status: 201});
    },
  });
  assert.equal(request.url, 'https://rtc.live.cloudflare.com/v1/turn/keys/key-123/credentials/generate-ice-servers');
  assert.equal(request.options.method, 'POST');
  assert.equal(request.options.headers.Authorization, 'Bearer server-only-token');
  assert.equal(request.options.headers['Content-Type'], 'application/json');
  assert.deepEqual(JSON.parse(request.options.body), {ttl: 2400});
  assert.deepEqual(iceServers, validIce.iceServers);
  assert.equal(JSON.stringify(iceServers).includes('server-only-token'), false);
});

test('rejects a key ID that could alter the fixed API path before fetching', async () => {
  const fetchCloudflareIceServers = await adapter();
  let called = false;
  await assert.rejects(fetchCloudflareIceServers({
    keyId: '../other', apiToken: 'server-only-token',
    fetchImpl: async () => { called = true; throw new Error('should not fetch'); },
  }), /TURN key ID/);
  assert.equal(called, false);
});

test('rejects a Cloudflare error without exposing the response body or token', async () => {
  const fetchCloudflareIceServers = await adapter();
  await assert.rejects(fetchCloudflareIceServers({
    keyId: 'key-123', apiToken: 'server-only-token',
    fetchImpl: async () => new Response('server-only-token in external error', {status: 429}),
  }), error => {
    assert.equal(error.message.includes('server-only-token'), false);
    assert.match(error.message, /TURN/);
    return true;
  });
});

test('aborts a stalled Cloudflare request', async () => {
  const fetchCloudflareIceServers = await adapter();
  await assert.rejects(fetchCloudflareIceServers({
    keyId: 'key-123', apiToken: 'server-only-token', timeoutMs: 10,
    fetchImpl: (_url, {signal}) => new Promise((_resolve, reject) => {
      signal.addEventListener('abort', () => reject(new Error('aborted')), {once: true});
    }),
  }), /TURN/);
});

for (const [name, response] of [
  ['missing TURN server', {iceServers: [{urls: ['stun:stun.cloudflare.com:3478']}]}],
  ['unexpected URL scheme', {iceServers: [{...validIce.iceServers[1], urls: ['https://other.example']}]}],
  ['missing TURN username', {iceServers: [{urls: ['turn:turn.cloudflare.com:3478'], credential: 'password'}]}],
  ['missing TURN credential', {iceServers: [{urls: ['turn:turn.cloudflare.com:3478'], username: 'user'}]}],
  ['malformed ICE list', {iceServers: 'not-an-array'}],
]) {
  test(`rejects ${name} instead of passing untrusted ICE to the App`, async () => {
    const fetchCloudflareIceServers = await adapter();
    await assert.rejects(fetchCloudflareIceServers({
      keyId: 'key-123', apiToken: 'server-only-token',
      fetchImpl: async () => new Response(JSON.stringify(response), {status: 201}),
    }), /TURN/);
  });
}
