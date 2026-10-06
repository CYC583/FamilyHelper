// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
/** Pure state transitions. Firebase runs these in ONE /core transaction.
 * No client can write roles, members, locks, pair codes, or session consent.
 * This single-family design prioritizes auditable atomicity over scalability.
 */
export const PAIR_TTL = 5 * 60_000;
export const REQUEST_TTL = 90_000;
export const LEASE_MS = 45_000;
export const SESSION_TTL = 30 * 60_000;
export const MAX_REGISTERED_DEVICES = 16;
/** New registrations per network per day: grandma + six family phones on one Wi-Fi, plus reinstalls. */
export const REGISTER_PER_IP_DAILY = 10;
export const MAX_FAMILY_CLIENTS = 6;
export class Fault extends Error {
  constructor(code, message) { super(message); this.code = code; }
}
const fail = (code, msg) => { throw new Fault(code, msg); };
export function role(s, uid, expected) {
  if (s.devices?.[uid]?.role !== expected) fail('permission-denied', '裝置角色不符');
}
export function member(s, host, uid) {
  if (!s.families?.[host]?.members?.[uid]) fail('permission-denied', '尚未綁定或已解除綁定');
}
export function live(session, now) {
  return !!session && ['pending', 'ringing', 'accepted'].includes(session.status) &&
    session.expiresAt > now && (session.status !== 'accepted' || session.leaseUntil > now);
}
export function rate(s, key, now, limit, windowMs) {
  s.rates ??= {};
  const r = s.rates[key];
  if (!r || now >= r.until) s.rates[key] = {count: 1, until: now + windowMs};
  else {
    if (r.count >= limit) fail('resource-exhausted', '操作太頻繁，請稍後再試');
    r.count++;
  }
}
export function register(s, uid, type, name, now) {
  if (!['host', 'client'].includes(type)) fail('invalid-argument', '未知角色');
  s.devices ??= {};
  if (s.devices[uid] && s.devices[uid].role !== type) fail('permission-denied', '無法變更角色');
  if (!s.devices[uid] && Object.keys(s.devices).length >= MAX_REGISTERED_DEVICES) {
    fail('resource-exhausted', '裝置數量已達上限，請聯絡管理者');
  }
  if (type === 'host' && !s.devices[uid] && Object.keys(s.families || {}).length) {
    fail('failed-precondition', '長輩端已設定，請聯絡管理者');
  }
  // A name chosen in 「我的名字與頭貼」 survives the app re-registering at start.
  const prior = s.devices[uid];
  s.devices[uid] = prior?.profileSetAt
    ? {...prior, role: type, updatedAt: now}
    : {role: type, name, updatedAt: now};
  if (type === 'host') {
    s.families ??= {};
    s.families[uid] ??= {name, createdAt: now};
  }
}
/** What the family calls grandma: the name she set on her phone. */
/** A family member's name as the family list shows it. */
export function memberName(core, hostId, uid) {
  const name = core?.families?.[hostId]?.members?.[uid]?.name || core?.devices?.[uid]?.name;
  return typeof name === 'string' && name.trim() ? name.trim() : '家人';
}

export function hostName(core, hostId) {
  const name = core?.families?.[hostId]?.name || core?.devices?.[hostId]?.name;
  return typeof name === 'string' && name.trim() ? name.trim() : '長輩';
}

export function alertPush(type, hostId, alertId, name = '長輩') {
  return type === 'sos' ? {
    title: `SOS ${name}緊急求助`,
    body: `${name}按了緊急求助！請立刻開啟 App 接聽通話，並直接打電話給${name}。`,
    data: {type, hostId, alertId},
  } : {
    title: `${name}找你`,
    body: `${name}按了呼叫，請開啟 App 接聽，可以看到${name}的手機畫面。`,
    data: {type, hostId, alertId},
  };
}

export function needsCleanup(s, now) {
  if (Object.values(s.pairCodes || {}).some(v => v.expiresAt <= now)) return true;
  if (Object.values(s.rates || {}).some(v => v.until <= now)) return true;
  if (Object.entries(s.sessions || {}).some(([id, v]) => !live(v, now) &&
    (['pending', 'ringing', 'accepted'].includes(v.status) ||
      s.families?.[v.hostId]?.activeSessionId === id ||
      now - v.createdAt > 24 * 60 * 60_000))) return true;
  return Object.values(s.families || {}).some(f =>
    Object.values(f.alerts || {}).some(v => now - v.createdAt > 7 * 24 * 60 * 60_000));
}
export function issueCode(s, uid, hash, now) {
  role(s, uid, 'host');
  const f = s.families[uid];
  if (Object.keys(f.members || {}).length >= MAX_FAMILY_CLIENTS) fail('resource-exhausted', '最多綁定六台家人手機，請先解除舊裝置');
  s.pairCodes ??= {};
  if (s.pairCodes[hash]?.expiresAt > now) fail('already-exists', '請重新產生配對碼');
  if (f.codeHash) delete s.pairCodes[f.codeHash];
  f.codeHash = hash;
  s.pairCodes[hash] = {hostId: uid, expiresAt: now + PAIR_TTL};
}
export function bind(s, uid, hash, now) {
  role(s, uid, 'client');
  if (s.links?.[uid]) fail('failed-precondition', '此控制端已綁定，請先解除');
  const c = s.pairCodes?.[hash];
  if (!c || c.expiresAt <= now) fail('not-found', '配對碼錯誤或已失效');
  const f = s.families[c.hostId];
  if (Object.keys(f.members || {}).length >= MAX_FAMILY_CLIENTS) fail('resource-exhausted', '已綁定六台家人手機');
  f.members ??= {};
  f.members[uid] = {name: s.devices[uid].name, boundAt: now};
  s.links ??= {};
  s.links[uid] = {hostId: c.hostId};
  delete s.pairCodes[hash];
  delete f.codeHash;
  return c.hostId;
}
export function requestSession(s, uid, host, id, now) {
  role(s, uid, 'client'); member(s, host, uid);
  const f = s.families[host];
  s.sessions ??= {};
  const prior = s.sessions[f.activeSessionId];
  if (live(prior, now)) fail('already-exists', '設備正在協助中，請稍後');
  if (prior) prior.status = 'expired';
  s.sessions[id] = {
    hostId: host, clientId: uid, clientName: memberName(s, host, uid),
    status: 'pending', createdAt: now, expiresAt: now + REQUEST_TTL,
  };
  f.activeSessionId = id;
}
export function getSession(s, uid, id) {
  const v = s.sessions?.[id];
  if (!v || ![v.hostId, v.clientId].includes(uid)) fail('permission-denied', '無權使用連線');
  member(s, v.hostId, v.clientId);
  return v;
}
export function accept(s, uid, id, now) {
  const v = getSession(s, uid, id);
  if (uid !== v.hostId || v.status !== 'pending' || !live(v, now)) fail('failed-precondition', '請求已結束');
  if (s.families[v.hostId].activeSessionId !== id) fail('failed-precondition', '請求已被取代');
  Object.assign(v, {status: 'accepted', acceptedAt: now, hostSeen: now,
    clientSeen: now, leaseUntil: now + LEASE_MS, expiresAt: now + SESSION_TTL});
}
export function finish(s, uid, id, reason, now) {
  const v = getSession(s, uid, id);
  if (uid === v.clientId && reason === 'rejected') fail('permission-denied', '只能由長輩拒絕');
  v.status = reason === 'rejected' ? 'rejected' : 'ended'; v.endedAt = now;
  if (s.families[v.hostId].activeSessionId === id) delete s.families[v.hostId].activeSessionId;
}
export function heartbeat(s, uid, id, now) {
  const v = getSession(s, uid, id);
  if (v.status !== 'accepted' || !live(v, now) || s.families[v.hostId].activeSessionId !== id) fail('failed-precondition', '連線已逾時');
  v[uid === v.hostId ? 'hostSeen' : 'clientSeen'] = now;
  v.leaseUntil = Math.min(v.hostSeen, v.clientSeen) + LEASE_MS;
}
export function revoke(s, uid, host, client, now) {
  if (uid !== host && uid !== client) fail('permission-denied', '不可解除他人裝置');
  member(s, host, client);
  const f = s.families[host];
  const v = s.sessions?.[f.activeSessionId];
  if (v?.clientId === client) { v.status = 'ended'; v.endedAt = now; delete f.activeSessionId; }
  // Keep the private photo ledger for retryable Storage cleanup, but make
  // prior uploads permanently unreadable even if this UID pairs again.
  for (const photo of Object.values(s.photoOps?.[host] || {})) {
    if (photo.authorId === client) photo.revokedAt = now;
  }
  delete f.members[client];
  if (s.links) delete s.links[client];
}
export function healthBreaches(data, thresholds, now) {
  const recent = item => item && Number.isFinite(item.value) &&
    Number.isFinite(item.time) && item.time <= now + 60_000 && now - item.time <= 15 * 60_000;
  const out = [];
  if (recent(data.heart) && ((Number.isFinite(thresholds.heartLow) && data.heart.value < thresholds.heartLow) ||
    (Number.isFinite(thresholds.heartHigh) && data.heart.value > thresholds.heartHigh))) out.push('heart');
  if (recent(data.oxygen) && Number.isFinite(thresholds.oxygenLow) && data.oxygen.value < thresholds.oxygenLow) out.push('oxygen');
  return out;
}


export const RING_TTL = 90_000;
/** Grandma pressed 呼叫 or SOS herself: that press is her local consent for
 * this one session. Any current family member may answer; the first wins.
 * Returns false (no call, alert still sent) when another session is live.
 */
export function ringFamily(s, uid, id, type, now, alertId = null) {
  role(s, uid, 'host');
  const f = s.families[uid];
  if (!Object.keys(f.members || {}).length) return false;
  s.sessions ??= {};
  if (live(s.sessions[f.activeSessionId], now)) return false;
  s.sessions[id] = {hostId: uid, clientId: null, type, shareScreen: type === 'call',
    status: 'ringing', createdAt: now, expiresAt: now + RING_TTL, ...(alertId ? {alertId} : {})};
  f.activeSessionId = id;
  return true;
}
export function answerRing(s, uid, id, now) {
  role(s, uid, 'client');
  const v = s.sessions?.[id];
  if (!v || v.status !== 'ringing' || v.expiresAt <= now) fail('failed-precondition', '來電已結束或已由其他家人接聽');
  member(s, v.hostId, uid);
  if (s.links?.[uid]?.hostId !== v.hostId) fail('permission-denied', '已解除配對');
  if (s.families[v.hostId].activeSessionId !== id) fail('failed-precondition', '來電已被取代');
  Object.assign(v, {clientId: uid, clientName: memberName(s, v.hostId, uid), status: 'accepted', acceptedAt: now,
    hostSeen: now, clientSeen: now, leaseUntil: now + LEASE_MS, expiresAt: now + SESSION_TTL});
  // Other family phones watch this to close their ringing screen.
  const alert = v.alertId ? s.families[v.hostId].alerts?.[v.alertId] : null;
  if (alert) alert.answeredBy = {uid, name: memberName(s, v.hostId, uid), at: now};
  return v;
}

/** Grandma stops a call she started before anyone answered. */
export function cancelRing(s, uid, id, now) {
  role(s, uid, 'host');
  const v = s.sessions?.[id];
  if (!v || v.hostId !== uid) fail('not-found', '找不到這次呼叫');
  if (v.status !== 'ringing') return v.status;
  v.status = 'ended';
  v.endedAt = now;
  if (s.families[uid].activeSessionId === id) delete s.families[uid].activeSessionId;
  const alert = v.alertId ? s.families[uid].alerts?.[v.alertId] : null;
  if (alert) alert.cancelledAt = now;
  return 'ended';
}
