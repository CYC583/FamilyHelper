// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import {Fault, role, member} from './state.js';

const kinds = new Set(['medicine', 'water', 'rest', 'photo']);
const invalid = () => { throw new Fault('invalid-argument', '請檢查提醒種類、時間與文字'); };

/** Family plans reminders; only the host may opt in to local speech. */
export function setReminderSettings(root, uid, hostId, input, now) {
  const core = root?.core || {};
  role(core, uid, 'client');
  role(core, hostId, 'host');
  member(core, hostId, uid);
  if (core.links?.[uid]?.hostId !== hostId) {
    throw new Fault('permission-denied', '尚未綁定或已解除綁定');
  }
  if (!Number.isSafeInteger(input?.expectedVersion) || input.expectedVersion < 0 ||
      !Array.isArray(input.items) || input.items.length > 12 ||
      !Number.isSafeInteger(now) || now < 0) invalid();

  const seen = new Set();
  const items = input.items.map(item => {
    const type = item?.type;
    const time = item?.time;
    const text = typeof item?.text === 'string' ? item.text.trim() : '';
    if (!kinds.has(type) || typeof time !== 'string' ||
        !/^(?:[01][0-9]|2[0-3]):[0-5][0-9]$/.test(time) ||
        text.length > 80 || /[\x00-\x1f<>]/.test(text) ||
        Object.keys(item).some(key => !['type', 'time', 'text'].includes(key))) invalid();
    const key = `${type}:${time}`;
    if (seen.has(key)) invalid();
    seen.add(key);
    return {type, time, text};
  }).sort((a, b) => a.time.localeCompare(b.time) || a.type.localeCompare(b.type));

  const currentVersion = root.care?.[hostId]?.settings?.reminders?.version || 0;
  if (currentVersion !== input.expectedVersion) {
    throw new Fault('aborted', '其他家人已更新提醒，請重新整理再儲存');
  }
  const next = {version: currentVersion + 1, timezone: 'Asia/Taipei', items,
    updatedAt: now, updatedBy: uid};
  root.care ??= {};
  root.care[hostId] ??= {};
  root.care[hostId].settings ??= {};
  root.care[hostId].settings.reminders = next;
  return next;
}
