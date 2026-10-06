// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import {Fault, role} from './state.js';

/** Leave/arrive alerts for grandma's home and workplace. Coordinates never
 * leave her phone: only "which place, enter or exit, when" is uploaded, and
 * only while her own itemised consent is on.
 */
export const PLACE_DISCLOSURE_VERSION = 1;
const PLACES = new Set(['home', 'work']);
const TRANSITIONS = new Set(['enter', 'exit']);
const KEEP_MS = 30 * 24 * 60 * 60_000;
const DEDUPE_MS = 10 * 60_000;
const fail = (code, message) => { throw new Fault(code, message); };

function hostOnly(core, uid, hostId) {
  role(core, hostId, 'host');
  if (uid !== hostId) fail('permission-denied', '只有長輩本機可以設定');
}

export function setPlaceAlerts(core, places, uid, hostId, input, now) {
  hostOnly(core, uid, hostId);
  const version = (places.consent?.version || 0) + 1;
  if (input?.enabled === true) {
    if (input.disclosureVersion !== PLACE_DISCLOSURE_VERSION) fail('failed-precondition', '請更新 App 並重新閱讀說明');
    const workName = typeof input.workName === 'string' && /^[\u4e00-\u9fffA-Za-z0-9 ]{1,8}$/.test(input.workName.trim())
      ? input.workName.trim() : '工作地點';
    places.consent = {enabled: true, status: 'enabled', version, disclosureVersion: PLACE_DISCLOSURE_VERSION,
      homeSet: input.homeSet === true, workSet: input.workSet === true, workName, updatedAt: now};
  } else if (input?.enabled === false) {
    places.consent = {enabled: false, status: input.revoke === true ? 'revoked' : 'paused', version,
      disclosureVersion: PLACE_DISCLOSURE_VERSION, homeSet: false, workSet: false, updatedAt: now};
    if (input.revoke === true) delete places.events;
  } else {
    fail('invalid-argument', '設定格式錯誤');
  }
  return places.consent;
}

/** Returns the stored event, or null when it duplicates a recent one. */
export function reportPlaceEvent(core, places, uid, hostId, input, now, id) {
  hostOnly(core, uid, hostId);
  const consent = places.consent;
  if (!consent?.enabled || consent.status !== 'enabled' || consent.disclosureVersion !== PLACE_DISCLOSURE_VERSION) {
    fail('failed-precondition', '長輩尚未開啟或已暫停出門到家通知');
  }
  if (input?.consentVersion !== consent.version) fail('failed-precondition', '設定已更新，請重新開啟 App');
  if (Object.keys(input || {}).some(k => !['place', 'transition', 'at', 'consentVersion'].includes(k)) ||
      !PLACES.has(input?.place) || !TRANSITIONS.has(input?.transition) ||
      !Number.isSafeInteger(input.at) || input.at > now + 60_000 || now - input.at > 6 * 60 * 60_000) {
    fail('invalid-argument', '事件格式錯誤');
  }
  places.events ??= {};
  for (const [key, e] of Object.entries(places.events)) if (now - e.receivedAt > KEEP_MS) delete places.events[key];
  const recent = Object.values(places.events).some(e => e.place === input.place &&
    e.transition === input.transition && Math.abs(e.at - input.at) < DEDUPE_MS);
  if (recent) return null;
  const keys = Object.keys(places.events).sort((a, b) => places.events[a].at - places.events[b].at);
  while (keys.length >= 200) delete places.events[keys.shift()];
  places.events[id] = {place: input.place, transition: input.transition, at: input.at, receivedAt: now};
  return places.events[id];
}

export function placeMessage(event, workName = '工作地點', name = '長輩') {
  const where = event.place === 'home' ? '家' : workName;
  const t = new Date(event.at + 8 * 3600_000);
  const hhmm = `${String(t.getUTCHours()).padStart(2, '0')}:${String(t.getUTCMinutes()).padStart(2, '0')}`;
  return event.transition === 'enter'
    ? {title: `${name}到${where}了`, body: `${hhmm} 抵達${where}。`}
    : {title: `${name}離開${where}了`, body: `${hhmm} 離開${where}。`};
}
