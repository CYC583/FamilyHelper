// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import {Fault, role, memberName} from './state.js';
import {authorizeMember} from './reminder_plan_state.js';

/** Grandma's live location for family, only after her own local consent.
 * Unlike place alerts, this uploads coordinates, so it has its own consent
 * and disclosure version. Pausing deletes the last stored position.
 */
export const LOCATION_DISCLOSURE_VERSION = 1;
export const LOCATE_COOLDOWN_MS = 15_000;
export const RING_COOLDOWN_MS = 30_000;
const fail = (code, message) => { throw new Fault(code, message); };

function hostOnly(core, uid, hostId) {
  role(core, hostId, 'host');
  if (uid !== hostId) fail('permission-denied', '只有長輩本機可以設定');
}

function active(loc) {
  const c = loc?.consent;
  if (!c?.enabled || c.status !== 'enabled' || c.disclosureVersion !== LOCATION_DISCLOSURE_VERSION) {
    fail('failed-precondition', '長輩尚未開啟或已暫停位置分享');
  }
  return c;
}

export function setLocationSharing(core, loc, uid, hostId, input, now) {
  hostOnly(core, uid, hostId);
  const version = (loc.consent?.version || 0) + 1;
  if (input?.enabled === true) {
    if (input.disclosureVersion !== LOCATION_DISCLOSURE_VERSION) fail('failed-precondition', '請更新 App 並重新閱讀說明');
    loc.consent = {enabled: true, status: 'enabled', version, disclosureVersion: LOCATION_DISCLOSURE_VERSION, updatedAt: now};
  } else if (input?.enabled === false) {
    loc.consent = {enabled: false, status: 'paused', version, disclosureVersion: LOCATION_DISCLOSURE_VERSION, updatedAt: now};
    delete loc.latest;
    delete loc.ring;
  } else {
    fail('invalid-argument', '設定格式錯誤');
  }
  return loc.consent;
}

export function reportLocation(core, loc, uid, hostId, input, now) {
  hostOnly(core, uid, hostId);
  const consent = active(loc);
  if (input?.consentVersion !== consent.version) fail('failed-precondition', '設定已更新，請重新開啟 App');
  const keys = ['lat', 'lng', 'accuracy', 'at', 'consentVersion'];
  if (Object.keys(input).some(k => !keys.includes(k)) ||
      typeof input.lat !== 'number' || !Number.isFinite(input.lat) || Math.abs(input.lat) > 90 ||
      typeof input.lng !== 'number' || !Number.isFinite(input.lng) || Math.abs(input.lng) > 180 ||
      typeof input.accuracy !== 'number' || !Number.isFinite(input.accuracy) || input.accuracy < 0 || input.accuracy > 50_000 ||
      !Number.isSafeInteger(input.at) || input.at > now + 60_000 || now - input.at > 24 * 60 * 60_000) {
    fail('invalid-argument', '位置格式錯誤');
  }
  if (loc.latest && input.at < loc.latest.at) return loc.latest; // an older fix never replaces a newer one
  loc.latest = {lat: Math.round(input.lat * 1e6) / 1e6, lng: Math.round(input.lng * 1e6) / 1e6,
    accuracy: Math.round(input.accuracy), at: input.at, receivedAt: now};
  return loc.latest;
}

/** A family member asks grandma's phone for a fresh position. */
export function requestLocate(core, loc, uid, hostId, now) {
  authorizeMember(core, uid, hostId);
  active(loc);
  if (now - (loc.lastRequestAt || 0) < LOCATE_COOLDOWN_MS) {
    throw new Fault('resource-exhausted', '剛剛已經請長輩手機更新位置，請稍等');
  }
  loc.lastRequestAt = now;
  return {ok: true};
}

/** "Play sound" on grandma's phone for ten seconds, like finding a phone. */
export function ringHost(core, loc, uid, hostId, now) {
  authorizeMember(core, uid, hostId);
  active(loc);
  if (now - (loc.ring?.at || 0) < RING_COOLDOWN_MS) {
    throw new Fault('resource-exhausted', '長輩手機剛響過，請 30 秒後再試');
  }
  loc.ring = {by: uid, name: memberName(core, hostId, uid), at: now};
  return loc.ring;
}
