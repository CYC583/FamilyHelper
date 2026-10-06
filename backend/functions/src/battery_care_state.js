// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
/** Pure transitions for one host's /care/{hostUid}/battery subtree.
 * Caller authorization and the atomic RTDB transaction are gateway duties.
 * Never perform I/O or send FCM from this module or a transaction callback.
 */
import {Fault} from './state.js';

const MINUTE_MS = 60_000;
const LOW_WAIT_MS = 30 * MINUTE_MS;
const CRITICAL_WAIT_MS = 5 * MINUTE_MS;
const MAX_EVIDENCE_MS = 7 * 24 * 60 * MINUTE_MS;
const MAX_CLOCK_SKEW_MS = 24 * 60 * MINUTE_MS;
export const BATTERY_DISCLOSURE_VERSION = 2;
const validId = value => typeof value === 'string' && /^[a-zA-Z0-9-]{1,64}$/.test(value);
const integer = value => Number.isSafeInteger(value);
const fail = (code, message) => { throw new Fault(code, message); };
const copy = value => structuredClone(value || {});

function validateClock(now) {
  if (!integer(now) || now < 0) fail('invalid-argument', '時間無效');
}

/** False pauses; explicit revoke permanently invalidates the prior share generation. */
export function setBatteryConsent(battery, hostUid, enabled, now,
  {revoke = false, disclosureVersion} = {}) {
  if (!validId(hostUid) || typeof enabled !== 'boolean' || typeof revoke !== 'boolean' ||
    (revoke && enabled)) fail('invalid-argument', '電量同意設定無效');
  validateClock(now);
  if (enabled && disclosureVersion !== BATTERY_DISCLOSURE_VERSION) {
    fail('failed-precondition', '請長輩重新確認電量分享說明');
  }
  const next = copy(battery);
  if (next.consent?.hostUid && next.consent.hostUid !== hostUid) {
    fail('permission-denied', '長輩身分不符');
  }
  const version = (next.consent?.version || 0) + 1;
  next.consent = {
    hostUid, enabled, status: enabled ? 'enabled' : revoke ? 'revoked' : 'paused',
    version, disclosureVersion: enabled ? disclosureVersion :
      next.consent?.disclosureVersion || 0, updatedAt: now,
  };
  next.replay ??= {lastSampleSeq: 0};
  if (!enabled) {
    delete next.latest;
    next.events = {};
    delete next.replay.lastSampleFingerprint;
    if (next.episode) next.episode = {id: next.episode.id, status: 'resolved'};
    if (revoke) next.preferences = {};
  }
  return next;
}

function validateSample(sample, now) {
  if (!sample || typeof sample !== 'object' || Array.isArray(sample)) {
    fail('invalid-argument', '電量樣本無效');
  }
  if (!integer(sample.batteryPercent) || sample.batteryPercent < 0 || sample.batteryPercent > 100 ||
    typeof sample.charging !== 'boolean' || !integer(sample.observedAt) ||
    Math.abs(now - sample.observedAt) > MAX_CLOCK_SKEW_MS || !validId(sample.episodeId) ||
    !integer(sample.sampleSeq) || sample.sampleSeq < 1 || !integer(sample.consentVersion) ||
    sample.consentVersion < 1) fail('invalid-argument', '電量樣本欄位無效');
  const low = !sample.charging && sample.batteryPercent <= 30;
  const severity = sample.batteryPercent <= 15 ? 'critical' : 'low';
  if (sample.phase !== (low ? 'low' : 'resolved') || sample.severity !== severity) {
    fail('invalid-argument', '電量狀態與實測數值不一致');
  }
  if (!low) return null;
  const e = sample.lowEvidence;
  if (!e || typeof e !== 'object' || Array.isArray(e) || !validId(e.bootEpoch) ||
    !integer(e.firstMonotonicMs) || !integer(e.currentMonotonicMs) ||
    e.firstMonotonicMs < 0 || e.currentMonotonicMs < e.firstMonotonicMs ||
    e.currentMonotonicMs - e.firstMonotonicMs > MAX_EVIDENCE_MS ||
    !integer(e.firstSampleSeq) || e.firstSampleSeq < 1 ||
    !integer(e.currentSampleSeq) || e.firstSampleSeq > e.currentSampleSeq ||
    e.currentSampleSeq !== sample.sampleSeq ||
    (e.firstSampleSeq === e.currentSampleSeq && e.firstMonotonicMs !== e.currentMonotonicMs)) {
    fail('invalid-argument', '低電量持續時間證據無效');
  }
  return e;
}

function fingerprint(sample) {
  const e = sample.lowEvidence;
  return JSON.stringify([
    sample.batteryPercent, sample.charging, sample.observedAt, sample.episodeId,
    sample.sampleSeq, sample.phase, sample.severity, sample.consentVersion,
    e && [e.bootEpoch, e.firstMonotonicMs, e.currentMonotonicMs, e.firstSampleSeq, e.currentSampleSeq],
  ]);
}

/** Accepts only the newest sample; consent/version, episode and seq fence stale retries. */
export function applyBatterySample(battery, sample, now) {
  validateClock(now);
  const evidence = validateSample(sample, now);
  const next = copy(battery);
  if (!next.consent?.enabled || next.consent.status !== 'enabled' ||
    next.consent.disclosureVersion !== BATTERY_DISCLOSURE_VERSION ||
    sample.consentVersion !== next.consent.version) {
    fail('failed-precondition', '長輩未同意分享電量或同意版本已失效');
  }
  next.replay ??= {lastSampleSeq: 0};
  const priorSeq = next.replay.lastSampleSeq || 0;
  if (sample.sampleSeq < priorSeq) fail('failed-precondition', '舊電量樣本已失效');
  const currentFingerprint = fingerprint(sample);
  if (sample.sampleSeq === priorSeq) {
    if (currentFingerprint === next.replay.lastSampleFingerprint) {
      return {battery: next, eventId: next.events?.[sample.episodeId] ? sample.episodeId : null, changed: false};
    }
    fail('failed-precondition', '相同序號的電量樣本不一致');
  }

  const priorEpisode = next.episode;
  if (sample.phase === 'low') {
    if (priorEpisode?.status === 'active' && priorEpisode.id !== sample.episodeId ||
      priorEpisode?.status === 'resolved' && priorEpisode.id === sample.episodeId) {
      fail('failed-precondition', '低電量 episode 已失效或識別碼不一致');
    }
    const rebooted = priorEpisode?.status === 'active' && priorEpisode.bootEpoch !== evidence.bootEpoch;
    if (rebooted && (evidence.firstSampleSeq !== sample.sampleSeq ||
      evidence.firstMonotonicMs !== evidence.currentMonotonicMs)) {
      fail('invalid-argument', '重開機後須重新累積低電量取樣');
    }
    if (priorEpisode?.status === 'active' && !rebooted &&
      (priorEpisode.firstSampleSeq !== evidence.firstSampleSeq ||
        priorEpisode.firstMonotonicMs !== evidence.firstMonotonicMs ||
        evidence.currentMonotonicMs <= priorEpisode.lastMonotonicMs)) {
      fail('invalid-argument', '同次低電量取樣證據不連續');
    }
    const episode = priorEpisode?.status === 'active' ? priorEpisode : {
      id: sample.episodeId, status: 'active', bootEpoch: evidence.bootEpoch,
      firstSampleSeq: evidence.firstSampleSeq, firstMonotonicMs: evidence.firstMonotonicMs,
    };
    if (rebooted) {
      episode.bootEpoch = evidence.bootEpoch;
      episode.firstSampleSeq = evidence.firstSampleSeq;
      episode.firstMonotonicMs = evidence.firstMonotonicMs;
      delete episode.firstCriticalMonotonicMs;
      delete episode.firstCriticalSampleSeq;
    }
    if (sample.severity === 'critical' && !integer(episode.firstCriticalMonotonicMs)) {
      // An offline first upload proves low duration, not necessarily that both
      // measurements were <=15%. Start the critical window at this sample.
      episode.firstCriticalMonotonicMs = evidence.currentMonotonicMs;
      episode.firstCriticalSampleSeq = sample.sampleSeq;
    }
    episode.lastMonotonicMs = evidence.currentMonotonicMs;
    episode.lastSampleSeq = sample.sampleSeq;
    next.episode = episode;
    next.events ??= {};
    const existing = next.events[sample.episodeId];
    if (existing) episode.eventCreated = true;
    const lowProven = evidence.firstSampleSeq < sample.sampleSeq &&
      evidence.currentMonotonicMs - evidence.firstMonotonicMs >= LOW_WAIT_MS;
    const criticalProven = sample.severity === 'critical' &&
      episode.firstCriticalSampleSeq < sample.sampleSeq &&
      evidence.currentMonotonicMs - episode.firstCriticalMonotonicMs >= CRITICAL_WAIT_MS;
    if (!existing && !episode.eventCreated && (lowProven || criticalProven)) {
      next.events[sample.episodeId] = {
        createdAt: now, severity: sample.severity, lastObservedAt: sample.observedAt,
        acknowledgedAt: {},
      };
      episode.eventCreated = true;
    } else if (existing) {
      existing.lastObservedAt = sample.observedAt;
      if (sample.severity === 'critical') existing.severity = 'critical';
    }
  } else if (priorEpisode?.status === 'active') {
    if (priorEpisode.id !== sample.episodeId) fail('failed-precondition', '解除樣本的 episode 不一致');
    next.episode = {id: priorEpisode.id, status: 'resolved', lastSampleSeq: sample.sampleSeq};
    if (next.events?.[sample.episodeId] && !next.events[sample.episodeId].resolvedAt) {
      next.events[sample.episodeId].resolvedAt = now;
      next.events[sample.episodeId].lastObservedAt = sample.observedAt;
    }
  } else if (priorEpisode?.id === sample.episodeId && priorEpisode.status === 'resolved') {
    // A later newer charging snapshot is fine; it never reopens the episode.
    next.episode.lastSampleSeq = sample.sampleSeq;
  }

  next.latest = {
    batteryPercent: sample.batteryPercent, charging: sample.charging,
    observedAt: sample.observedAt, receivedAt: now, episodeId: sample.episodeId,
    sampleSeq: sample.sampleSeq, phase: sample.phase, severity: sample.severity,
  };
  next.replay.lastSampleSeq = sample.sampleSeq;
  next.replay.lastSampleFingerprint = currentFingerprint;
  return {battery: next, eventId: next.events?.[sample.episodeId] ? sample.episodeId : null, changed: true};
}

export function ackBatteryEvent(battery, eventId, memberUid, now) {
  if (!validId(eventId) || !validId(memberUid)) fail('invalid-argument', '事件或家人識別碼無效');
  validateClock(now);
  const next = copy(battery);
  if (!next.consent?.enabled) fail('failed-precondition', '長輩未同意分享電量');
  const event = next.events?.[eventId];
  if (!event) fail('not-found', '電量事件不存在');
  event.acknowledgedAt ??= {};
  event.acknowledgedAt[memberUid] ??= now;
  return next;
}

export function setBatteryPreference(battery, memberUid, preference, now) {
  if (!validId(memberUid) || !preference || typeof preference !== 'object' ||
    typeof preference.enabled !== 'boolean' || typeof preference.soundEnabled !== 'boolean') {
    fail('invalid-argument', '通知偏好無效');
  }
  validateClock(now);
  const quiet = preference.quietHours;
  const validTime = value => typeof value === 'string' && /^([01]\d|2[0-3]):[0-5]\d$/.test(value);
  if (quiet !== undefined && (quiet === null || !validTime(quiet.start) || !validTime(quiet.end))) {
    fail('invalid-argument', '安靜時段無效');
  }
  if (preference.timeZone !== undefined) {
    try { new Intl.DateTimeFormat('en-US', {timeZone: preference.timeZone}); } catch {
      fail('invalid-argument', '時區無效');
    }
  }
  const next = copy(battery);
  next.preferences ??= {};
  next.preferences[memberUid] = {
    enabled: preference.enabled, soundEnabled: preference.soundEnabled,
    ...(quiet ? {quietHours: {start: quiet.start, end: quiet.end}} : {}),
    ...(preference.timeZone ? {timeZone: preference.timeZone} : {}), updatedAt: now,
  };
  return next;
}
