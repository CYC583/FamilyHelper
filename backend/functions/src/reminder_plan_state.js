// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import {Fault, role, member, memberName} from './state.js';

/** Family-scheduled reminders, v2: daily or one-off, text and/or a family
 * voice recording. Stored at care/{host}/settings/reminderPlan so phones still
 * on the v1 `reminders` format are not broken by the new fields.
 */
export const MAX_PLAN_ITEMS = 30;
export const MAX_REMINDER_VOICES = 40;
const TYPES = new Set(['medicine', 'water', 'rest', 'photo', 'custom']);
const TIME = /^(?:[01][0-9]|2[0-3]):[0-5][0-9]$/;
const ID = /^[a-z0-9-]{1,40}$/;
const TAIPEI_OFFSET_MS = 8 * 60 * 60_000;
const fail = (message) => { throw new Fault('invalid-argument', message); };
export const taipeiDay = now => new Date(now + TAIPEI_OFFSET_MS).toISOString().slice(0, 10);

export function authorizeMember(core, uid, hostId) {
  role(core, uid, 'client');
  role(core, hostId, 'host');
  member(core, hostId, uid);
  if (core.links?.[uid]?.hostId !== hostId) throw new Fault('permission-denied', '尚未綁定或已解除綁定');
}

function cleanText(value) {
  const text = typeof value === 'string' ? value.trim() : '';
  if (text.length > 80 || /[\x00-\x1f<>]/.test(text)) fail('提醒文字請在 80 字內，不要換行或輸入 < >');
  return text;
}

/** Pure transition inside a root transaction. newId() supplies ids for new rows. */
export function setReminderPlan(root, uid, hostId, input, now, newId) {
  const core = root?.core || {};
  authorizeMember(core, uid, hostId);
  if (!Number.isSafeInteger(input?.expectedVersion) || input.expectedVersion < 0 ||
      !Array.isArray(input.items) || input.items.length > MAX_PLAN_ITEMS) {
    fail(`提醒最多 ${MAX_PLAN_ITEMS} 個`);
  }
  const care = root.care?.[hostId] || {};
  const current = care.settings?.reminderPlan;
  if ((current?.version || 0) !== input.expectedVersion) {
    throw new Fault('aborted', '其他家人剛更新了提醒，請重新整理再儲存');
  }
  const previous = new Map((current?.items || []).map(item => [item.id, item]));
  const voices = care.reminderVoices || {};
  const today = taipeiDay(now);
  const seen = new Set();
  const items = [];
  for (const raw of input.items) {
    const keys = ['id', 'type', 'repeat', 'date', 'days', 'pausedUntil', 'time', 'text', 'voiceId'];
    if (!raw || typeof raw !== 'object' || Object.keys(raw).some(k => !keys.includes(k))) fail('提醒格式錯誤');
    if (!TYPES.has(raw.type)) fail('提醒種類錯誤');
    if (typeof raw.time !== 'string' || !TIME.test(raw.time)) fail('提醒時間錯誤');
    const repeat = ['once', 'weekly'].includes(raw.repeat) ? raw.repeat
      : raw.repeat === 'daily' || raw.repeat == null ? 'daily' : fail('重複方式錯誤');
    let days = null;
    if (repeat === 'weekly') {
      if (!Array.isArray(raw.days) || !raw.days.length || raw.days.some(d => !Number.isInteger(d) || d < 1 || d > 7)) {
        fail('請選擇星期幾');
      }
      days = [...new Set(raw.days)].sort();
    }
    let pausedUntil = null;
    if (raw.pausedUntil != null && raw.pausedUntil !== '') {
      if (typeof raw.pausedUntil !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(raw.pausedUntil) ||
          taipeiDay(Date.parse(`${raw.pausedUntil}T00:00:00+08:00`)) !== raw.pausedUntil) fail('暫停日期錯誤');
      if (raw.pausedUntil >= today) pausedUntil = raw.pausedUntil;
    }
    let date = null;
    if (repeat === 'once') {
      if (typeof raw.date !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(raw.date) ||
          taipeiDay(Date.parse(`${raw.date}T00:00:00+08:00`)) !== raw.date) fail('提醒日期錯誤');
      if (raw.date < today) continue; // past one-off reminders are dropped
      date = raw.date;
    }
    const text = cleanText(raw.text);
    let voiceId = null;
    if (raw.voiceId != null && raw.voiceId !== '') {
      if (typeof raw.voiceId !== 'string' || !ID.test(raw.voiceId) || voices[raw.voiceId]?.status !== 'ready') {
        fail('提醒語音不存在，請重新錄音');
      }
      voiceId = raw.voiceId;
    }
    if (!text && !voiceId && raw.type === 'custom') fail('自訂提醒需要文字或語音');
    const id = typeof raw.id === 'string' && ID.test(raw.id) && previous.has(raw.id) ? raw.id : newId();
    if (seen.has(id)) fail('提醒重複');
    seen.add(id);
    const old = previous.get(id);
    const row = {id, type: raw.type, repeat, ...(date ? {date} : {}), ...(days ? {days} : {}),
      ...(pausedUntil ? {pausedUntil} : {}), time: raw.time, text, ...(voiceId ? {voiceId} : {})};
    const same = old && ['type', 'repeat', 'date', 'time', 'text', 'voiceId', 'pausedUntil']
      .every(k => (old[k] ?? null) === (row[k] ?? null)) &&
      JSON.stringify(old.days || null) === JSON.stringify(row.days || null);
    items.push({...row,
      createdBy: old?.createdBy || uid, author: old?.author || memberName(core, hostId, old?.createdBy || uid),
      editedBy: same ? old.editedBy || old.author : memberName(core, hostId, uid),
      updatedAt: same ? old.updatedAt : now});
  }
  items.sort((a, b) => (a.date || '').localeCompare(b.date || '') || a.time.localeCompare(b.time));
  const next = {version: (current?.version || 0) + 1, timezone: 'Asia/Taipei', items, updatedAt: now, updatedBy: uid};
  root.care ??= {};
  root.care[hostId] ??= {};
  root.care[hostId].settings ??= {};
  root.care[hostId].settings.reminderPlan = next;
  return next;
}

/** Reserve a voice slot; bytes are saved to private Storage after this. */
export function reserveReminderVoice(core, voices, uid, hostId, id, input, now) {
  authorizeMember(core, uid, hostId);
  if (!ID.test(id) || Object.hasOwn(voices, id)) fail('語音識別碼錯誤');
  if (!Number.isSafeInteger(input?.durationMs) || input.durationMs < 500 || input.durationMs > 30_000 ||
      typeof input.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(input.sha256)) fail('語音需為 30 秒以內');
  if (Object.keys(voices).length >= MAX_REMINDER_VOICES) {
    throw new Fault('resource-exhausted', '提醒語音太多了，請先刪除不用的提醒');
  }
  voices[id] = {createdBy: uid, sha256: input.sha256, durationMs: input.durationMs, status: 'pending',
    createdAt: now, objectPath: `care-reminder-voice/${hostId}/${id}.m4a`};
  return voices[id];
}

export function finishReminderVoice(voices, uid, id, now) {
  const v = voices[id];
  if (!v || v.createdBy !== uid || v.status !== 'pending' || now - v.createdAt > 10 * 60_000) {
    throw new Fault('failed-precondition', '語音上傳已逾時，請重錄');
  }
  v.status = 'ready';
  return v;
}

export function readableReminderVoice(core, voices, uid, hostId, id) {
  role(core, hostId, 'host');
  if (uid !== hostId) authorizeMember(core, uid, hostId);
  const v = Object.hasOwn(voices, id) ? voices[id] : null;
  if (!v || v.status !== 'ready') throw new Fault('not-found', '提醒語音不存在');
  return v;
}

/** A family member's own intro clip ("長輩，我是小明") and whether they join
 * the daily weather rotation. Only the member themself can set theirs.
 */
export function setVoiceProfile(core, care, uid, hostId, input, now) {
  authorizeMember(core, uid, hostId);
  const voiceId = input?.introVoiceId;
  if (voiceId != null && voiceId !== '' &&
      (typeof voiceId !== 'string' || !ID.test(voiceId) || care.reminderVoices?.[voiceId]?.status !== 'ready' ||
        care.reminderVoices[voiceId].createdBy !== uid)) {
    fail('自我介紹錄音不存在，請重新錄音');
  }
  if (typeof input?.joinWeather !== 'boolean') fail('設定格式錯誤');
  const profile = {name: memberName(core, hostId, uid), joinWeather: input.joinWeather && !!voiceId,
    ...(voiceId ? {introVoiceId: voiceId} : {}), updatedAt: now};
  care.voiceProfiles ??= {};
  care.voiceProfiles[uid] = profile;
  return profile;
}

/** Voices not used by the plan or a profile for a day are deleted. */
export function unusedReminderVoices(care, now) {
  const used = new Set([
    ...(care?.settings?.reminderPlan?.items || []).map(i => i.voiceId),
    ...Object.values(care?.voiceProfiles || {}).map(p => p.introVoiceId),
  ].filter(Boolean));
  return Object.entries(care?.reminderVoices || {})
    .filter(([id, v]) => !used.has(id) && now - (v.createdAt || 0) > 24 * 60 * 60_000)
    .map(([id, v]) => ({id, objectPath: v.objectPath}));
}
