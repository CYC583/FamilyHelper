// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import {Fault, role} from './state.js';

/** What grandma's phone reports about family reminders: which plan version it
 * has, and per reminder whether it played. "played" is the phone's playback
 * result only — never proof that she heard it or did the task.
 */
const STATES = new Set(['played', 'text_fallback', 'silent', 'failed']);
const KEY = /^\d{4}-\d{2}-\d{2}:[a-z0-9:-]{1,60}$/;
const KEEP_DAYS = 14;
const fail = (message) => { throw new Fault('invalid-argument', message); };
const day = ms => new Date(ms + 8 * 3600_000).toISOString().slice(0, 10);

export function reportReminderStatus(core, status, uid, hostId, input, now) {
  role(core, hostId, 'host');
  if (uid !== hostId) throw new Fault('permission-denied', '只有長輩手機可以回報');
  if (!Number.isSafeInteger(input?.planVersion) || input.planVersion < 0) fail('版本錯誤');
  const list = Array.isArray(input.deliveries) ? input.deliveries : [];
  if (list.length > 40) fail('一次回報太多');
  status.sync = {version: input.planVersion, at: now};
  status.days ??= {};
  for (const d of list) {
    if (!d || typeof d.key !== 'string' || !KEY.test(d.key) || !STATES.has(d.state) ||
        !Number.isSafeInteger(d.at) || d.at > now + 60_000 || now - d.at > 2 * 86400_000) fail('回報格式錯誤');
    const date = d.key.slice(0, 10);
    const id = d.key.slice(11).replace(/:/g, '_');
    status.days[date] ??= {};
    status.days[date][id] = {state: d.state, at: d.at, receivedAt: now};
  }
  const oldest = day(now - KEEP_DAYS * 86400_000);
  for (const date of Object.keys(status.days)) if (date < oldest) delete status.days[date];
  return {ok: true, sync: status.sync};
}
