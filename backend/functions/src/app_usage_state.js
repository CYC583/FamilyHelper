// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import {Fault, role} from './state.js';
import {taipeiDay} from './reminder_plan_state.js';

/** How long grandma used each app per day, only after her own local consent
 * and Android's usage-access permission (which she turns on herself). Only
 * app names and minutes are stored, never what she did inside an app.
 */
export const USAGE_DISCLOSURE_VERSION = 1;
export const USAGE_KEEP_DAYS = 7;
export const MAX_APPS = 30;
const DAY_MS = 24 * 60 * 60_000;
const fail = (code, message) => { throw new Fault(code, message); };

function hostOnly(core, uid, hostId) {
  role(core, hostId, 'host');
  if (uid !== hostId) fail('permission-denied', '只有長輩本機可以設定');
}

export function setAppUsageSharing(core, usage, uid, hostId, input, now) {
  hostOnly(core, uid, hostId);
  const version = (usage.consent?.version || 0) + 1;
  if (input?.enabled === true) {
    if (input.disclosureVersion !== USAGE_DISCLOSURE_VERSION) fail('failed-precondition', '請更新 App 並重新閱讀說明');
    usage.consent = {enabled: true, status: 'enabled', version, disclosureVersion: USAGE_DISCLOSURE_VERSION, updatedAt: now};
  } else if (input?.enabled === false) {
    usage.consent = {enabled: false, status: 'paused', version, disclosureVersion: USAGE_DISCLOSURE_VERSION, updatedAt: now};
    delete usage.days;
  } else {
    fail('invalid-argument', '設定格式錯誤');
  }
  return usage.consent;
}

export function reportAppUsage(core, usage, uid, hostId, input, now) {
  hostOnly(core, uid, hostId);
  const c = usage.consent;
  if (!c?.enabled || c.status !== 'enabled' || c.disclosureVersion !== USAGE_DISCLOSURE_VERSION) {
    fail('failed-precondition', '長輩尚未開啟或已暫停使用時間分享');
  }
  if (input?.consentVersion !== c.version) fail('failed-precondition', '設定已更新，請重新開啟 App');
  const today = taipeiDay(now), yesterday = taipeiDay(now - DAY_MS);
  if (Object.keys(input).some(k => !['date', 'apps', 'consentVersion'].includes(k)) ||
      ![today, yesterday].includes(input.date) || !Array.isArray(input.apps) || input.apps.length > MAX_APPS) {
    fail('invalid-argument', '使用時間格式錯誤');
  }
  const apps = [];
  for (const raw of input.apps) {
    const name = typeof raw?.name === 'string' ? raw.name.trim() : '';
    if (!raw || Object.keys(raw).some(k => !['name', 'minutes'].includes(k)) ||
        !name || name.length > 40 || /[\x00-\x1f<>]/.test(name) ||
        !Number.isInteger(raw.minutes) || raw.minutes < 1 || raw.minutes > 1440) {
      fail('invalid-argument', '使用時間格式錯誤');
    }
    apps.push({name, minutes: raw.minutes});
  }
  apps.sort((a, b) => b.minutes - a.minutes || a.name.localeCompare(b.name));
  usage.days ??= {};
  const oldest = taipeiDay(now - (USAGE_KEEP_DAYS - 1) * DAY_MS);
  for (const day of Object.keys(usage.days)) if (day < oldest) delete usage.days[day];
  usage.days[input.date] = {apps, total: apps.reduce((s, a) => s + a.minutes, 0), updatedAt: now};
  return usage.days[input.date];
}
