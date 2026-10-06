// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
/** I/O boundary for battery care. Inject Firebase operations for emulator and
 * concurrency tests; all transaction callbacks are pure and retry-safe.
 */
import {randomUUID} from 'node:crypto';
import {Fault, role, member} from './state.js';
import {
  setBatteryConsent, applyBatterySample, ackBatteryEvent, setBatteryPreference,
  BATTERY_DISCLOSURE_VERSION,
} from './battery_care_state.js';

const fail = (code, message) => { throw new Fault(code, message); };
const validId = value => typeof value === 'string' && /^[a-zA-Z0-9-]{1,64}$/.test(value);

function currentMember(core, hostId, uid) {
  role(core, uid, 'client');
  role(core, hostId, 'host');
  member(core, hostId, uid);
  if (core.links?.[uid]?.hostId !== hostId) fail('permission-denied', '已解除家人配對');
}

function quietNow(preference, now) {
  const quiet = preference?.quietHours;
  if (!quiet || !preference.timeZone) return false;
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: preference.timeZone, hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).formatToParts(new Date(now));
  const hour = parts.find(part => part.type === 'hour')?.value;
  const minute = parts.find(part => part.type === 'minute')?.value;
  const here = `${hour}:${minute}`;
  if (quiet.start === quiet.end) return false;
  return quiet.start < quiet.end ? here >= quiet.start && here < quiet.end :
    here >= quiet.start || here < quiet.end;
}

export function createBatteryGateway(deps) {
  for (const key of ['readCore', 'readBattery', 'transactBattery', 'transactRoot', 'readToken', 'sendOne', 'clock']) {
    if (typeof deps?.[key] !== 'function') throw new Error(`Battery gateway missing ${key}`);
  }

  async function reserve(hostId, eventId, uid, sampleSeq, now) {
    const attemptId = randomUUID(); // Outside the retryable transaction callback.
    const root = await deps.transactRoot(state => {
      currentMember(state.core || {}, hostId, uid);
      const battery = state.care?.[hostId]?.battery;
      if (!battery?.consent?.enabled || battery.consent.status !== 'enabled' ||
        battery.consent.disclosureVersion !== BATTERY_DISCLOSURE_VERSION) {
        fail('failed-precondition', '長輩已停止分享電量');
      }
      const event = battery.events?.[eventId];
      if (!event || event.resolvedAt) fail('failed-precondition', '電量事件已解除');
      const preference = battery.preferences?.[uid] || {enabled: true, soundEnabled: false};
      if (!preference.enabled) return;
      battery.pushOps ??= {};
      battery.pushOps[eventId] ??= {};
      const previous = battery.pushOps[eventId][uid];
      if (previous && (previous.status !== 'failed' || previous.attempts >= 2 ||
        previous.sampleSeq === sampleSeq)) return;
      battery.pushOps[eventId][uid] = {
        attemptId, attempts: (previous?.attempts || 0) + 1, status: 'unknown',
        attemptedAt: now, sampleSeq,
      };
    });
    const battery = root.care?.[hostId]?.battery;
    const record = battery?.pushOps?.[eventId]?.[uid];
    if (record?.attemptId !== attemptId) return null;
    const preference = battery.preferences?.[uid] || {enabled: true, soundEnabled: false};
    return {attemptId, soundEnabled: preference.soundEnabled && !quietNow(preference, now)};
  }

  async function recordResult(hostId, eventId, uid, attemptId, status, now) {
    await deps.transactRoot(root => {
      const record = root.care?.[hostId]?.battery?.pushOps?.[eventId]?.[uid];
      if (!record || record.attemptId !== attemptId || record.status !== 'unknown') return;
      record.status = status;
      if (status === 'accepted') record.acceptedAt = now;
      else if (status === 'failed') record.failedAt = now;
    });
  }

  async function pushForEvent(hostId, eventId, sampleSeq, now) {
    const core = await deps.readCore();
    const members = Object.keys(core.families?.[hostId]?.members || {});
    const summary = {attempted: 0, accepted: 0, failed: 0, unknown: 0};
    for (const uid of members) {
      let hold;
      try { hold = await reserve(hostId, eventId, uid, sampleSeq, now); }
      catch (error) {
        if (error instanceof Fault && ['permission-denied', 'failed-precondition'].includes(error.code)) continue;
        throw error;
      }
      if (!hold) continue;
      let status = 'unknown';
      try {
        const token = await deps.readToken(uid);
        const freshCore = await deps.readCore();
        const freshBattery = await deps.readBattery(hostId);
        // A member may have been unpaired after reservation. Do not begin FCM.
        try { currentMember(freshCore, hostId, uid); } catch { continue; }
        if (!freshBattery?.consent?.enabled || freshBattery.consent.status !== 'enabled' ||
          freshBattery.consent.disclosureVersion !== BATTERY_DISCLOSURE_VERSION ||
          !freshBattery.events?.[eventId] || freshBattery.events[eventId].resolvedAt ||
          freshBattery.preferences?.[uid]?.enabled === false) continue;
        if (!token?.token) status = 'failed';
        else {
          const result = await deps.sendOne({
            uid, token: token.token,
            data: {type: 'careBattery', hostId, eventId},
            title: '手機電量提醒', body: '請開啟 App 查看守護狀態。',
            channelId: hold.soundEnabled ? 'care_battery_sound' : 'care_battery_silent',
            soundEnabled: hold.soundEnabled, tag: eventId,
          });
          status = ['accepted', 'failed'].includes(result?.status || result) ?
            (result?.status || result) : 'unknown';
        }
      } catch { status = 'unknown'; }
      await recordResult(hostId, eventId, uid, hold.attemptId, status, deps.clock());
      summary.attempted++;
      summary[status]++;
    }
    return summary;
  }

  return {
    // Exposed only for dependency injection in deterministic tests.
    deps,
    async setBatteryConsent(uid, input) {
      role(await deps.readCore(), uid, 'host');
      if (typeof input?.enabled !== 'boolean' || !Number.isSafeInteger(input.expectedVersion) ||
        input.expectedVersion < 0 || (input.revoke !== undefined && typeof input.revoke !== 'boolean')) {
        fail('invalid-argument', '電量同意設定無效');
      }
      const battery = await deps.transactBattery(uid, current => {
        if ((current.consent?.version || 0) !== input.expectedVersion) {
          fail('failed-precondition', '電量同意狀態已更新，請重新開啟設定');
        }
        return setBatteryConsent(current, uid, input.enabled, deps.clock(), {
          revoke: input.revoke || false, disclosureVersion: input.disclosureVersion,
        });
      });
      return battery.consent;
    },
    async reportBatterySample(uid, input) {
      role(await deps.readCore(), uid, 'host');
      if (!input?.sample || !Number.isSafeInteger(input.consentVersion)) {
        fail('invalid-argument', '電量上報資料無效');
      }
      const now = deps.clock();
      const sample = {...input.sample, consentVersion: input.consentVersion};
      const battery = await deps.transactBattery(uid, current => applyBatterySample(current, sample, now).battery);
      const eventId = battery.events?.[sample.episodeId] && !battery.events[sample.episodeId].resolvedAt ?
        sample.episodeId : null;
      const pushAttempt = eventId ? await pushForEvent(uid, eventId, sample.sampleSeq, now) :
        {attempted: 0, accepted: 0, failed: 0, unknown: 0};
      return {syncedAt: battery.latest?.receivedAt || now, eventId, pushAttempt};
    },
    async ackBatteryEvent(uid, input) {
      if (!validId(input?.hostId) || !validId(input?.eventId)) fail('invalid-argument', '電量事件識別碼無效');
      const now = deps.clock();
      const root = await deps.transactRoot(current => {
        currentMember(current.core || {}, input.hostId, uid);
        const battery = current.care?.[input.hostId]?.battery;
        if (!battery) fail('not-found', '電量守護尚未開通');
        current.care[input.hostId].battery = ackBatteryEvent(battery, input.eventId, uid, now);
      });
      return {acknowledgedAt: root.care[input.hostId].battery.events[input.eventId].acknowledgedAt[uid]};
    },
    async setBatteryNotificationPreference(uid, input) {
      if (!validId(input?.hostId)) fail('invalid-argument', '長輩識別碼無效');
      const now = deps.clock();
      const root = await deps.transactRoot(current => {
        currentMember(current.core || {}, input.hostId, uid);
        current.care ??= {};
        current.care[input.hostId] ??= {};
        const battery = current.care[input.hostId].battery || {};
        current.care[input.hostId].battery = setBatteryPreference(battery, uid, input, now);
      });
      return root.care[input.hostId].battery.preferences[uid];
    },
  };
}
