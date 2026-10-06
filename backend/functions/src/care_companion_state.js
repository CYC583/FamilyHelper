// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import {Fault, role, member} from './state.js';

/** Pure companion transitions. Callers pass a fresh /core snapshot for
 * authorization and a /care/{host} subtree that is updated in its own
 * transaction. Nothing here sends a push or touches Storage.
 */
export const COMPANION_DISCLOSURE_VERSION = 1;
export const MEDIA_TTL_MS = 30 * 24 * 60 * 60_000;
// No practical family limit (user decision 2026-10-03); a high ceiling only
// stops a runaway client from filling the private bucket.
export const TEXT_DAILY_LIMIT = 500;
export const VOICE_DAILY_LIMIT = 500;
export const VOICE_MAX_MS = 30_000;
export const SOUND_ALERT_AFTER_MS = 60 * 60_000;
export const LIVENESS_STALE_MS = 3 * 60 * 60_000;
const DAY_MS = 24 * 60 * 60_000;
const TAIPEI_OFFSET_MS = 8 * 60 * 60_000;
const KEEP_DAYS = 30;
const ITEMS = ['responses', 'mood', 'sound'];
const REMINDER_TYPES = new Set(['medicine', 'water', 'rest', 'photo']);
const RESPONSES = new Set(['done', 'later', 'skip']);
const MOODS = new Set(['good', 'ok', 'tired', 'bad']);
const RINGERS = new Set(['normal', 'vibrate', 'silent']);
const TIME = /^(?:[01][0-9]|2[0-3]):[0-5][0-9]$/;

const fail = (code, message) => { throw new Fault(code, message); };
export const taipeiDay = now => new Date(now + TAIPEI_OFFSET_MS).toISOString().slice(0, 10);

function hostOnly(core, uid, hostId) {
  role(core, hostId, 'host');
  if (uid !== hostId) fail('permission-denied', '只有長輩本機可以操作');
}

/** Host or a family member who is still bound to this host. */
export function authorizeFamily(core, uid, hostId) {
  role(core, hostId, 'host');
  if (uid === hostId) return;
  role(core, uid, 'client');
  member(core, hostId, uid);
  if (core.links?.[uid]?.hostId !== hostId) fail('permission-denied', '已解除家人配對');
}

function cleanText(value, max) {
  const text = typeof value === 'string' ? value.trim() : '';
  if (!text || text.length > max || /[\x00-\x1f<>]/.test(text)) {
    fail('invalid-argument', `文字需為 1 到 ${max} 字，不能含特殊符號`);
  }
  return text;
}

/** Recent Taipei calendar day only; replies cannot be back-filled weeks later. */
function recentDay(value, now) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) fail('invalid-argument', '日期格式錯誤');
  const at = Date.parse(`${value}T00:00:00+08:00`);
  if (!Number.isFinite(at) || taipeiDay(at) !== value) fail('invalid-argument', '日期格式錯誤');
  const today = Date.parse(`${taipeiDay(now)}T00:00:00+08:00`);
  if (at > today || today - at > DAY_MS) fail('invalid-argument', '只能記錄今天或昨天');
  return value;
}

function activeItem(companion, item, consentVersion) {
  const consent = companion.consent;
  if (!consent?.enabled || consent.status !== 'enabled' ||
      consent.disclosureVersion !== COMPANION_DISCLOSURE_VERSION || consent.items?.[item] !== true) {
    fail('failed-precondition', '長輩尚未同意分享這一項，或已暫停分享');
  }
  if (consentVersion !== consent.version) fail('failed-precondition', '分享同意已更新，請重新開啟 App');
  return consent;
}

/** Host-only. Enable needs the current itemised disclosure; pause keeps old
 * shared rows hidden by rules, revoke deletes them so a later grant starts empty.
 */
export function setCompanionConsent(core, companion, uid, hostId, input, now) {
  hostOnly(core, uid, hostId);
  if (!Number.isSafeInteger(now)) fail('invalid-argument', '時間無效');
  const version = (companion.consent?.version || 0) + 1;
  if (input?.action === 'enable') {
    if (input.disclosureVersion !== COMPANION_DISCLOSURE_VERSION) {
      fail('failed-precondition', '請更新 App 並重新閱讀分享說明');
    }
    const items = Object.fromEntries(ITEMS.map(key => [key, input.items?.[key] === true]));
    if (!Object.values(items).some(Boolean)) fail('invalid-argument', '至少選一項才能開啟分享');
    companion.consent = {enabled: true, status: 'enabled', items, version,
      disclosureVersion: COMPANION_DISCLOSURE_VERSION, updatedAt: now};
  } else if (input?.action === 'pause' || input?.action === 'revoke') {
    const status = input.action === 'pause' ? 'paused' : 'revoked';
    companion.consent = {enabled: false, status, items: {responses: false, mood: false, sound: false},
      version, disclosureVersion: COMPANION_DISCLOSURE_VERSION, updatedAt: now};
    delete companion.sound?.episode;
    if (status === 'revoked') { delete companion.responses; delete companion.mood; delete companion.sound; }
  } else {
    fail('invalid-argument', '未知的分享操作');
  }
  return companion.consent;
}

/** Stores only type/time/answer. Medicine names never leave the phone. */
export function recordReminderResponse(core, companion, uid, hostId, input, now) {
  hostOnly(core, uid, hostId);
  activeItem(companion, 'responses', input?.consentVersion);
  const allowed = ['date', 'type', 'time', 'response', 'respondedAt', 'consentVersion'];
  if (!input || Object.keys(input).some(key => !allowed.includes(key)) ||
      !REMINDER_TYPES.has(input.type) || typeof input.time !== 'string' || !TIME.test(input.time) ||
      !RESPONSES.has(input.response)) fail('invalid-argument', '提醒回覆格式錯誤');
  const date = recentDay(input.date, now);
  const respondedAt = Number.isSafeInteger(input.respondedAt) && input.respondedAt <= now + 60_000
    ? input.respondedAt : now;
  const row = {type: input.type, time: input.time, response: input.response, respondedAt, receivedAt: now};
  companion.responses ??= {};
  companion.responses[date] ??= {};
  companion.responses[date][`${input.type}_${input.time.replace(':', '')}`] = row;
  return row;
}

export function recordMood(core, companion, uid, hostId, input, now) {
  hostOnly(core, uid, hostId);
  activeItem(companion, 'mood', input?.consentVersion);
  if (!MOODS.has(input?.mood)) fail('invalid-argument', '心情選項錯誤');
  const date = recentDay(input.date, now);
  const row = {mood: input.mood, recordedAt: now};
  companion.mood ??= {};
  companion.mood[date] = row;
  return row;
}

/** Keeps only the latest sound state and an episode; returns a push decision
 * once per continuous silent/DND episode lasting at least one hour.
 */
export function reportSoundStatus(core, companion, uid, hostId, input, now) {
  hostOnly(core, uid, hostId);
  activeItem(companion, 'sound', input?.consentVersion);
  if (!RINGERS.has(input?.ringer) || typeof input.dnd !== 'boolean' ||
      typeof input.mediaZero !== 'boolean' || !Number.isSafeInteger(input.observedAt) ||
      input.observedAt > now + 60_000 || now - input.observedAt > DAY_MS) {
    fail('invalid-argument', '聲音狀態格式錯誤');
  }
  companion.sound ??= {};
  const prior = companion.sound.latest;
  if (prior && input.observedAt < prior.observedAt) fail('failed-precondition', '舊的聲音狀態已失效');
  companion.sound.latest = {ringer: input.ringer, dnd: input.dnd, mediaZero: input.mediaZero,
    observedAt: input.observedAt, receivedAt: now};
  const quiet = input.ringer === 'silent' || input.dnd;
  if (!quiet) { delete companion.sound.episode; return {notify: null}; }
  const episode = companion.sound.episode ??= {id: `sound-${input.observedAt}`, startedAt: input.observedAt};
  if (!episode.notifiedAt && input.observedAt - episode.startedAt >= SOUND_ALERT_AFTER_MS) {
    episode.notifiedAt = now;
    return {notify: {type: 'sound', eventId: episode.id}};
  }
  return {notify: null};
}

function dayCount(items, uid, kind, day) {
  return Object.values(items).filter(item => item.authorId === uid && item.kind === kind &&
    taipeiDay(item.createdAt) === day).length;
}

/** Message metadata. Voice bytes are stored privately by the caller after this. */
export function addMessage(core, items, uid, hostId, input, now, id) {
  authorizeFamily(core, uid, hostId);
  if (typeof id !== 'string' || !/^[a-zA-Z0-9-]{1,64}$/.test(id) || Object.hasOwn(items, id)) {
    fail('invalid-argument', '留言識別碼無效');
  }
  const day = taipeiDay(now);
  const base = {authorId: uid, createdAt: now, expiresAt: now + MEDIA_TTL_MS};
  if (input?.kind === 'text') {
    const text = cleanText(input.text, 80);
    if (dayCount(items, uid, 'text', day) >= TEXT_DAILY_LIMIT) fail('resource-exhausted', '今天的文字留言已達上限');
    items[id] = {...base, kind: 'text', text};
  } else if (input?.kind === 'voice') {
    if (!Number.isSafeInteger(input.durationMs) || input.durationMs < 500 || input.durationMs > VOICE_MAX_MS ||
        typeof input.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(input.sha256)) {
      fail('invalid-argument', '語音需為 30 秒以內');
    }
    if (dayCount(items, uid, 'voice', day) >= VOICE_DAILY_LIMIT) fail('resource-exhausted', '今天的語音留言已達上限');
    items[id] = {...base, kind: 'voice', durationMs: input.durationMs, sha256: input.sha256,
      status: 'pending', objectPath: `care-voice/${hostId}/${id}.m4a`};
  } else {
    fail('invalid-argument', '不支援的留言類型');
  }
  return items[id];
}

/** Publish a voice note only after its private object was written. */
export function finalizeVoice(core, items, uid, hostId, id, now) {
  authorizeFamily(core, uid, hostId);
  const item = Object.hasOwn(items, id) ? items[id] : null;
  if (!item || item.kind !== 'voice' || item.authorId !== uid) fail('failed-precondition', '語音留言已失效');
  if (item.status === 'ready') return item;
  if (item.status !== 'pending' || now - item.createdAt > 10 * 60_000) fail('failed-precondition', '語音上傳已逾時');
  item.status = 'ready';
  item.readyAt = now;
  return item;
}

function authorStillPresent(core, hostId, authorId) {
  return authorId === hostId || !!core.families?.[hostId]?.members?.[authorId];
}

export function readableMessage(core, items, uid, hostId, id, now) {
  authorizeFamily(core, uid, hostId);
  const item = Object.hasOwn(items, id) ? items[id] : null;
  if (!item || item.expiresAt <= now || !authorStillPresent(core, hostId, item.authorId) ||
      (item.kind === 'voice' && item.status !== 'ready')) {
    fail('not-found', '留言不存在或已到期');
  }
  return item;
}

function visiblePhoto(core, hostId, mediaId, now, ignorePause = false) {
  const consent = core.families?.[hostId]?.photoConsent;
  if (!consent || (!consent.enabled && !ignorePause)) fail('failed-precondition', '長輩尚未同意分享照片或已暫停');
  const members = core.families[hostId].members || {};
  return Object.values(core.photoOps?.[hostId] || {}).some(op => op.mediaId === mediaId &&
    op.status === 'ready' && op.shareGeneration === consent.shareGeneration && op.expiresAt > now &&
    !Number.isFinite(op.revokedAt) && (op.authorId === hostId || !!members[op.authorId]));
}

export function reactToPhoto(core, reactions, uid, hostId, input, now) {
  authorizeFamily(core, uid, hostId);
  if (typeof input?.mediaId !== 'string' || !/^[a-zA-Z0-9-]{1,128}$/.test(input.mediaId) ||
      typeof input.heart !== 'boolean') fail('invalid-argument', '照片互動格式錯誤');
  if (!visiblePhoto(core, hostId, input.mediaId, now)) fail('not-found', '照片不存在或已到期');
  const comment = input.comment == null || input.comment === '' ? '' : cleanText(input.comment, 60);
  reactions[input.mediaId] ??= {};
  reactions[input.mediaId][uid] = {heart: input.heart, comment, updatedAt: now};
  return reactions[input.mediaId][uid];
}

/** What grandma hears after a family member reacts to her photo, or null
 * when nothing new happened (e.g. a heart taken back, the same comment).
 */
export function photoReactionLine(before, after) {
  const newHeart = after?.heart === true && before?.heart !== true;
  const comment = after?.comment || '';
  const newComment = comment !== '' && comment !== (before?.comment || '');
  if (newComment) return `我在你的照片留言：${comment}`.slice(0, 80);
  if (newHeart) return '我在你的照片按了愛心';
  return null;
}

/** Server-time staleness only. Never reports paused/revoked sharing as offline. */
export function livenessStep(battery, companion, now) {
  const consent = battery?.consent;
  const sharing = consent?.enabled === true && consent.status === 'enabled' && consent.disclosureVersion === 2;
  const reference = Math.max(Number(battery?.latest?.receivedAt) || 0, Number(consent?.updatedAt) || 0);
  const stale = sharing && reference > 0 && now - reference >= LIVENESS_STALE_MS;
  const prior = companion.liveness;
  if (stale && prior?.state !== 'suspected') {
    companion.liveness = {state: 'suspected', since: reference, id: `offline-${reference}`, notifiedAt: now};
    return {notify: true, eventId: companion.liveness.id};
  }
  if (!stale && prior?.state === 'suspected') {
    companion.liveness = {...prior, state: 'resolved', resolvedAt: now};
  }
  return {notify: false};
}

/** Bounded retention; returns private voice objects the caller must delete. */
export function companionCleanup(core, careHost, now, hostId = 'grandma') {
  const oldest = taipeiDay(now - KEEP_DAYS * DAY_MS);
  for (const key of ['responses', 'mood']) {
    for (const day of Object.keys(careHost.companion?.[key] || {})) {
      if (day < oldest) delete careHost.companion[key][day];
    }
  }
  const voiceObjects = [];
  for (const [id, item] of Object.entries(careHost.messages?.items || {})) {
    const stalePending = item.kind === 'voice' && item.status === 'pending' && now - item.createdAt > 10 * 60_000;
    if (item.expiresAt <= now || !authorStillPresent(core, hostId, item.authorId) || stalePending) {
      if (item.objectPath) voiceObjects.push({id, objectPath: item.objectPath});
      delete careHost.messages.items[id];
    }
  }
  for (const [mediaId, byUser] of Object.entries(careHost.photoReactions || {})) {
    if (!visiblePhotoQuiet(core, hostId, mediaId, now)) { delete careHost.photoReactions[mediaId]; continue; }
    for (const uid of Object.keys(byUser)) {
      if (!authorStillPresent(core, hostId, uid)) delete byUser[uid];
    }
  }
  return {voiceObjects};
}

/** Pausing photo sharing hides reactions via rules; only gone media drop them. */
function visiblePhotoQuiet(core, hostId, mediaId, now) {
  const consent = core.families?.[hostId]?.photoConsent;
  if (!consent) return false;
  try { return visiblePhoto(core, hostId, mediaId, now, true); } catch { return false; }
}
