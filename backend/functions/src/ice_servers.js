// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import {createHmac} from 'node:crypto';
import {fetchCloudflareIceServers} from './cloudflare_turn.js';

const STUN = {urls: ['stun:stun.l.google.com:19302']};
// tool/setup.py stores this value when a family does not use Cloudflare TURN,
// because Firebase requires every declared secret to exist at deploy time.
const DISABLED = 'disabled';
const configured = value => (value && value !== DISABLED ? value : '');

export async function resolveIceServers({
  uid, now, cloudflareKeyId, cloudflareToken, turnUrl, turnSecret, fetchImpl,
}) {
  const fallback = () => ({iceServers: [STUN], hasTurn: false});
  cloudflareKeyId = configured(cloudflareKeyId);
  cloudflareToken = configured(cloudflareToken);
  turnSecret = configured(turnSecret);
  if (cloudflareKeyId || cloudflareToken) {
    if (!cloudflareKeyId || !cloudflareToken) return fallback();
    try {
      const servers = await fetchCloudflareIceServers({
        keyId: cloudflareKeyId, apiToken: cloudflareToken, fetchImpl,
      });
      return {iceServers: [STUN, ...servers], hasTurn: true};
    } catch {
      return fallback();
    }
  }
  if (!turnUrl || !turnSecret) return fallback();
  const username = `${Math.floor(now / 1000) + 3600}:${uid}`;
  const credential = createHmac('sha1', turnSecret).update(username).digest('base64');
  return {
    iceServers: [STUN, {urls: turnUrl.split(',').map(value => value.trim()), username, credential}],
    hasTurn: true,
  };
}
