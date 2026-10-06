// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
const API_BASE = 'https://rtc.live.cloudflare.com/v1/turn/keys';
const MAX_RESPONSE_BYTES = 32_768;
const MAX_ICE_SERVERS = 8;
const MAX_URLS = 12;

function validUrl(url) {
  if (typeof url !== 'string' || url.length > 512) return false;
  return /^(?:stun:stun\.cloudflare\.com|turns?:turn\.cloudflare\.com):\d{1,5}(?:\?transport=(?:udp|tcp))?$/.test(url);
}

function validateIceServers(data) {
  if (!Array.isArray(data?.iceServers) || !data.iceServers.length || data.iceServers.length > MAX_ICE_SERVERS) {
    throw new Error('TURN credentials invalid');
  }
  let hasTurn = false;
  const servers = data.iceServers.map(server => {
    const urls = typeof server?.urls === 'string' ? [server.urls] : server?.urls;
    if (!Array.isArray(urls) || !urls.length || urls.length > MAX_URLS || !urls.every(validUrl)) {
      throw new Error('TURN credentials invalid');
    }
    const needsAuth = urls.some(url => url.startsWith('turn:') || url.startsWith('turns:'));
    if (!needsAuth) return {urls};
    hasTurn = true;
    if (typeof server.username !== 'string' || !server.username || server.username.length > 512 ||
        typeof server.credential !== 'string' || !server.credential || server.credential.length > 512) {
      throw new Error('TURN credentials invalid');
    }
    return {urls, username: server.username, credential: server.credential};
  });
  if (!hasTurn) throw new Error('TURN credentials invalid');
  return servers;
}

export async function fetchCloudflareIceServers({
  keyId, apiToken, ttlSeconds = 2400, timeoutMs = 4000, fetchImpl = fetch,
}) {
  if (typeof keyId !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(keyId)) {
    throw new Error('TURN key ID invalid');
  }
  if (typeof apiToken !== 'string' || !apiToken || apiToken.length > 4096) {
    throw new Error('TURN token unavailable');
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetchImpl(`${API_BASE}/${keyId}/credentials/generate-ice-servers`, {
      method: 'POST',
      headers: {Authorization: `Bearer ${apiToken}`, 'Content-Type': 'application/json'},
      body: JSON.stringify({ttl: ttlSeconds}),
      signal: controller.signal,
    });
    if (response.status !== 201) throw new Error('TURN request failed');
    const body = await response.text();
    if (body.length > MAX_RESPONSE_BYTES) throw new Error('TURN response too large');
    return validateIceServers(JSON.parse(body));
  } catch {
    // Never expose API responses, the long-term token, or temporary ICE credentials in errors.
    throw new Error('TURN request failed');
  } finally {
    clearTimeout(timer);
  }
}
