// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import {randomInt, randomUUID, createHmac, createHash} from 'node:crypto';
import {initializeApp} from 'firebase-admin/app';
import {getDatabaseWithUrl} from 'firebase-admin/database';
import {getMessaging} from 'firebase-admin/messaging';
import {getStorage} from 'firebase-admin/storage';
import {onCall, HttpsError} from 'firebase-functions/v2/https';
import {onSchedule} from 'firebase-functions/v2/scheduler';
import {defineSecret, defineString} from 'firebase-functions/params';
import * as model from './state.js';
import {transact} from './atomic.js';
import {resolveIceServers} from './ice_servers.js';
import {createPhotoGateway, runPhotoCleanup} from './photo_gateway.js';
import * as photoState from './photo_state.js';
import {createBatteryGateway} from './battery_care_gateway.js';
import {runBatteryCleanup} from './battery_care_cleanup.js';
import {setWeatherSettings as updateWeatherSettings} from './weather_settings_state.js';
import {setReminderSettings as updateReminderSettings} from './reminder_settings_state.js';
import {createCompanionGateway, decodeVoice} from './care_companion_gateway.js';
import * as reminderPlan from './reminder_plan_state.js';
import * as placeAlerts from './place_alert_state.js';
import * as contacts from './contact_state.js';
import {reportReminderStatus as reminderStatusTransition} from './reminder_status_state.js';
import {setHandling as handlingTransition} from './handling_state.js';
import * as locationState from './location_state.js';
import * as usageState from './app_usage_state.js';
import * as profileState from './profile_state.js';
import * as digest from './care_digest_state.js';

initializeApp();
const DATABASE_URL = defineString('FAMILYHELPER_DATABASE_URL');
const STORAGE_BUCKET = defineString('FAMILYHELPER_STORAGE_BUCKET', {default: ''});
const db = () => getDatabaseWithUrl(DATABASE_URL.value());
const PAIR_PEPPER = defineSecret('PAIR_PEPPER');
const TURN_SECRET = defineSecret('TURN_SECRET');
const TURN_URL = defineString('TURN_URL', {default: ''});
const CLOUDFLARE_TURN_KEY_ID = defineSecret('CLOUDFLARE_TURN_KEY_ID');
const CLOUDFLARE_TURN_API_TOKEN = defineSecret('CLOUDFLARE_TURN_API_TOKEN');
const region = 'asia-east1';
const text = (v, max = 80) => typeof v === 'string' ? v.trim().slice(0, max) : '';
function required(v, max = 128) {
  const out = text(v, max);
  if (!out || /[.#$\[\]\/]/.test(out)) throw new HttpsError('invalid-argument', '無效識別碼');
  return out;
}
function callable(fn, secrets = [], options = {}) {
  return onCall({region, secrets, maxInstances: 5, timeoutSeconds: 30, ...options}, async request => {
    if (!request.auth) throw new HttpsError('unauthenticated', '請重新開啟 App');
    try { return await fn(request.auth.uid, request.data || {}, request); }
    catch (e) {
      if (e instanceof model.Fault) throw new HttpsError(e.code, e.message);
      if (e instanceof HttpsError) throw e;
      // Do not return credentials, SDP, tokens, health data, or internal stack traces.
      throw new HttpsError('internal', '服務暫時無法使用，請稍後再試');
    }
  });
}
/** Firebase retries this callback on contention. The callback must remain pure. */
async function atomic(update) {
  return transact(db().ref('core'), update);
}
function photoGateway() {
  const name = STORAGE_BUCKET.value();
  if (!name || !/^[a-z0-9][a-z0-9.-]{1,220}[a-z0-9]$/.test(name)) {
    throw new HttpsError('failed-precondition', '照片服務尚未完成設定');
  }
  return createPhotoGateway({
    readCore: async () => (await db().ref('core').get()).val() || {},
    atomic,
    bucket: getStorage().bucket(name),
  });
}
function batteryGateway() {
  return createBatteryGateway({
    readCore: async () => (await db().ref('core').get()).val() || {},
    readBattery: async hostId => (await db().ref(`care/${hostId}/battery`).get()).val() || {},
    // Existing transact() callbacks mutate their argument; the pure battery
    // transition returns a replacement subtree instead.
    transactBattery,
    transactRoot: update => transact(db().ref(), update),
    readToken: async uid => (await db().ref(`pushTokens/${uid}`).get()).val(),
    sendOne: async message => {
      try {
        await getMessaging().send({
          token: message.token,
          notification: {title: message.title, body: message.body},
          data: message.data,
          android: {priority: 'high', ttl: 120_000, notification: {
            channelId: message.channelId, tag: message.tag,
            ...(message.soundEnabled ? {sound: 'default'} : {}),
          }},
        });
        return 'accepted'; // FCM acceptance is not device delivery.
      } catch (error) {
        if (['messaging/registration-token-not-registered', 'messaging/invalid-registration-token']
          .includes(error?.code)) {
          await db().ref(`pushTokens/${message.uid}`).transaction(value =>
            value?.token === message.token ? null : value);
          return 'failed';
        }
        return 'unknown';
      }
    },
    clock: Date.now,
  });
}
function companionGateway() {
  const name = STORAGE_BUCKET.value();
  const valid = name && /^[a-z0-9][a-z0-9.-]{1,220}[a-z0-9]$/.test(name);
  return createCompanionGateway({
    readCore: async () => (await db().ref('core').get()).val() || {},
    readCare: async (hostId, child) => (await db().ref(`care/${hostId}/${child}`).get()).val(),
    transactCare: (hostId, child, update) => transact(db().ref(child ? `care/${hostId}/${child}` : `care/${hostId}`), update),
    // Voice notes share the private photo bucket; text/consent work without it.
    bucket: valid ? getStorage().bucket(name) : null,
    // Grandma's phone gets a data-only message so it can read it aloud itself;
    // family phones get a normal visible notification.
    notify: async (uids, title, body, data) => {
      const host = uids.filter(uid => uid === data.hostId);
      const family = uids.filter(uid => uid !== data.hostId);
      const [a, b] = await Promise.all([
        family.length ? push(family, title, body, data) : {accepted: 0, failed: 0},
        host.length ? pushData(host, data) : {accepted: 0, failed: 0},
      ]);
      return {accepted: a.accepted + b.accepted, failed: a.failed + b.failed};
    },
  });
}
function transactBattery(hostId, update) {
  return transact(db().ref(`care/${hostId}/battery`), current => {
    const next = update(current);
    for (const key of Object.keys(current)) delete current[key];
    Object.assign(current, next);
  });
}
const hashCode = code => createHmac('sha256', PAIR_PEPPER.value()).update(code).digest('hex');
export const registerDevice = callable(async (uid, d, request) => {
  const name = text(d.name, 24) || (d.role === 'host' ? '長輩' : '家人');
  const now = Date.now();
  // Registration is anonymous by design. Bound new registrations by address as
  // well as total devices so one caller cannot cheaply fill a billed database.
  const ip = createHash('sha256').update(request.rawRequest.ip || 'unknown').digest('hex');
  await atomic(s => {
    model.rate(s, `register_uid_${uid}`, now, 20, 60 * 60_000);
    if (!s.devices?.[uid]) model.rate(s, `register_ip_${ip}`, now, model.REGISTER_PER_IP_DAILY, 24 * 60 * 60_000);
    model.register(s, uid, d.role, name, now);
  });
  return {uid};
});
export const savePushToken = callable(async (uid, d) => {
  const token = text(d.token, 4096);
  if (!token) throw new HttpsError('invalid-argument', '通知識別碼為空');
  if (!(await db().ref(`core/devices/${uid}`).get()).exists()) throw new HttpsError('failed-precondition', '未註冊裝置');
  await db().ref(`pushTokens/${uid}`).set({token, updatedAt: Date.now()});
  return {ok: true};
});
export const createPairCode = callable(async uid => {
  const now = Date.now();
  const code = String(randomInt(0, 1_000_000)).padStart(6, '0');
  await atomic(s => { model.rate(s, `issue_${uid}`, now, 10, 60_000); model.issueCode(s, uid, hashCode(code), now); });
  return {code, expiresAt: now + model.PAIR_TTL};
}, [PAIR_PEPPER]);
export const pairDevice = callable(async (uid, d, request) => {
  const now = Date.now();
  // Count invalid guesses in a separately committed transaction; otherwise failed
  // pairing would roll back its own rate limit. Hash the address, never store it raw.
  const ip = createHash('sha256').update(request.rawRequest.ip || 'unknown').digest('hex');
  await atomic(s => {
    model.role(s, uid, 'client');
    model.rate(s, `pair_${uid}`, now, 5, 10 * 60_000);
    model.rate(s, `ip_${ip}`, now, 20, 10 * 60_000);
  });
  if (typeof d.code !== 'string' || !/^\d{6}$/.test(d.code)) throw new HttpsError('invalid-argument', '請輸入六位數配對碼');
  const s = await atomic(s => model.bind(s, uid, hashCode(d.code), now));
  return s.links[uid];
}, [PAIR_PEPPER]);

async function push(uids, title, body, data) {
  const entries = await Promise.all([...new Set(uids)].map(async uid => ({uid, value: (await db().ref(`pushTokens/${uid}`).get()).val()})));
  const valid = entries.filter(e => e.value?.token);
  if (!valid.length) return {accepted: 0, failed: uids.length};
  try {
    const response = await getMessaging().sendEachForMulticast({
      tokens: valid.map(e => e.value.token), notification: {title, body}, data,
      android: {priority: 'high', ttl: 120_000, notification: {channelId: 'family_alerts', sound: 'default'}},
    });
    await Promise.all(response.responses.map(async (r, i) => {
      if (['messaging/registration-token-not-registered', 'messaging/invalid-registration-token'].includes(r.error?.code)) {
        // Avoid deleting a token refreshed while this request was in flight.
        await db().ref(`pushTokens/${valid[i].uid}`).transaction(v => v?.token === valid[i].value.token ? null : v);
      }
    }));
    return {accepted: response.successCount, failed: response.failureCount + uids.length - valid.length};
  } catch { return {accepted: 0, failed: uids.length}; }
}
/** Data-only, high priority: lets grandma's native receiver speak the update. */
async function pushData(uids, data) {
  const entries = await Promise.all([...new Set(uids)].map(async uid => ({uid, value: (await db().ref(`pushTokens/${uid}`).get()).val()})));
  const valid = entries.filter(e => e.value?.token);
  if (!valid.length) return {accepted: 0, failed: uids.length};
  try {
    const response = await getMessaging().sendEachForMulticast({
      tokens: valid.map(e => e.value.token), data, android: {priority: 'high', ttl: 600_000},
    });
    return {accepted: response.successCount, failed: response.failureCount + uids.length - valid.length};
  } catch { return {accepted: 0, failed: uids.length}; }
}
export const requestHelp = callable(async (uid, d) => {
  const id = randomUUID(), hostId = required(d.hostId), now = Date.now();
  await atomic(s => { model.rate(s, `request_${uid}`, now, 6, 60_000); model.requestSession(s, uid, hostId, id, now); });
  const notification = await push([hostId], '家人想幫忙', '請開啟 FamilyHelper，選擇同意或拒絕。', {type: 'request', sessionId: id, hostId});
  return {sessionId: id, notification};
});
export const answerHostCall = callable(async (uid, d) => {
  const v = (await atomic(s => model.answerRing(s, uid, required(d.sessionId), Date.now()))).sessions[required(d.sessionId)];
  return {sessionId: d.sessionId, shareScreen: v.shareScreen === true, type: v.type};
});
export const cancelHostCall = callable(async (uid, d) => {
  let state;
  await atomic(s => { state = model.cancelRing(s, uid, required(d.sessionId), Date.now()); });
  return {status: state};
});
export const setContactPhone = callable(async (uid, d) => {
  const hostId = required(d.hostId);
  const core = (await db().ref('core').get()).val() || {};
  let result;
  await transact(db().ref(`care/${hostId}/contacts`), list => { result = contacts.setContactPhone(core, list, uid, hostId, d, Date.now()); });
  return {contact: result};
}, [], {minInstances: 0, maxInstances: 1});
export const confirmContactPhone = callable(async (uid, d) => {
  const core = (await db().ref('core').get()).val() || {};
  let result;
  await transact(db().ref(`care/${uid}/contacts`), list => { result = contacts.confirmContactPhone(core, list, uid, uid, d, Date.now()); });
  return {contact: result};
}, [], {minInstances: 0, maxInstances: 1});
export const acceptHelp = callable(async (uid, d) => {
  await atomic(s => model.accept(s, uid, required(d.sessionId), Date.now())); return {ok: true};
});
export const endHelp = callable(async (uid, d) => {
  await atomic(s => model.finish(s, uid, required(d.sessionId), d.reason, Date.now())); return {ok: true};
});
export const heartbeat = callable(async (uid, d) => {
  await atomic(s => model.heartbeat(s, uid, required(d.sessionId), Date.now())); return {ok: true};
});
export const unpairDevice = callable(async (uid, d) => {
  await atomic(s => model.revoke(s, uid, required(d.hostId), required(d.clientId), Date.now())); return {ok: true};
});
function location(value) {
  if (!value || !Number.isFinite(value.lat) || !Number.isFinite(value.lng) ||
    Math.abs(value.lat) > 90 || Math.abs(value.lng) > 180 || !Number.isFinite(value.time) ||
    !Number.isFinite(value.accuracy) || value.accuracy < 0 || Math.abs(Date.now() - value.time) > 120_000) return null;
  return {lat: value.lat, lng: value.lng, accuracy: value.accuracy, time: value.time};
}
export const sendAlert = callable(async (uid, d) => {
  if (!['sos', 'call'].includes(d.type)) throw new HttpsError('invalid-argument', '不支援的告警');
  const now = Date.now(), alertId = randomUUID(), sessionId = randomUUID();
  const loc = d.type === 'sos' ? location(d.location) : null;
  let ringing = false;
  await atomic(s => {
    model.role(s, uid, 'host'); model.rate(s, `alert_${uid}`, now, 6, 60_000);
    const f = s.families[uid];
    if (!Object.keys(f.members || {}).length) throw new model.Fault('failed-precondition', '尚未綁定家人，無法通知');
    // Older apps do not send withCall; they keep the alert-only behaviour.
    ringing = d.withCall === true && model.ringFamily(s, uid, sessionId, d.type, now, alertId);
    f.alerts ??= {}; f.alerts[alertId] = {type: d.type, createdAt: now, ...(loc ? {location: loc} : {}),
      ...(ringing ? {sessionId} : {})};
  });
  // A pairing may be revoked between the alert write and FCM send. Re-read
  // members and keep location out of the push payload in either case.
  const family = (await db().ref(`core/families/${uid}`).get()).val() || {};
  const members = family.members || {};
  const notification = model.alertPush(d.type, uid, alertId, model.hostName({families: {[uid]: family}}, uid));
  const data = ringing ? {...notification.data, sessionId} : notification.data;
  const result = await push(Object.keys(members), notification.title, notification.body, data);
  await db().ref(`core/families/${uid}/alerts/${alertId}/push`).set(result);
  return {alertId, ...result, locationIncluded: !!loc, sessionId: ringing ? sessionId : null};
});
export const acknowledgeAlert = callable(async (uid, d) => {
  const host = required(d.hostId), id = required(d.alertId);
  await atomic(s => {
    model.member(s, host, uid);
    const alert = s.families[host].alerts?.[id];
    if (!alert) throw new model.Fault('not-found', '通知已過期');
    alert.receipts ??= {}; alert.receipts[uid] = Date.now();
  }); return {ok: true};
});
export const getIceServers = callable(async (uid, d) => {
  const s = (await db().ref('core').get()).val() || {};
  const v = model.getSession(s, uid, required(d.sessionId));
  if (!model.live(v, Date.now()) || v.status !== 'accepted') throw new HttpsError('failed-precondition', '連線尚未同意');
  return resolveIceServers({
    uid, now: Date.now(),
    cloudflareKeyId: CLOUDFLARE_TURN_KEY_ID.value(),
    cloudflareToken: CLOUDFLARE_TURN_API_TOKEN.value(),
    turnUrl: TURN_URL.value(), turnSecret: TURN_SECRET.value(),
  });
}, [TURN_SECRET, CLOUDFLARE_TURN_KEY_ID, CLOUDFLARE_TURN_API_TOKEN]);
export const submitHealth = callable(async (uid, d) => {
  const now = Date.now(), id = randomUUID();
  const data = {};
  for (const key of ['heart', 'oxygen', 'sleep']) {
    const v = d.data?.[key];
    if (v && Number.isFinite(v.value) && v.value >= 0 && Number.isFinite(v.time) && v.time <= now + 60_000) data[key] = {value: v.value, time: v.time};
  }
  const thresholds = {};
  for (const key of ['heartLow', 'heartHigh', 'oxygenLow']) if (Number.isFinite(d.thresholds?.[key])) thresholds[key] = d.thresholds[key];
  const s = await atomic(s => {
    model.role(s, uid, 'host'); model.rate(s, `health_${uid}`, now, 6, 60_000);
    const f = s.families[uid];
    f.health = {...data, syncedAt: now};
    const breaches = model.healthBreaches(data, thresholds, now);
    const sample = breaches.map(k => `${k}:${data[k].time}`).join('|');
    if (sample && sample !== f.lastHealthSample && now - (f.lastHealthAlert || 0) >= 15 * 60_000) {
      f.lastHealthSample = sample; f.lastHealthAlert = now;
      f.alerts ??= {}; f.alerts[id] = {type: 'health', createdAt: now, fields: breaches.join(',')};
    }
  });
  if (s.families[uid].alerts?.[id]) await push(Object.keys(s.families[uid].members || {}), '健康數值提醒', `有新數值超出家人自行設定的範圍，請開啟 App 查看記錄時間並聯絡${model.hostName(s, uid)}。`, {type: 'health', hostId: uid, alertId: id});
  return {ok: true};
});
export const clearHealth = callable(async uid => {
  await atomic(s => { model.role(s, uid, 'host'); delete s.families[uid].health; }); return {ok: true};
});
export const setBatteryConsent = callable(async (uid, d) => batteryGateway().setBatteryConsent(uid, d));
export const setWeatherSettings = callable(async (uid, d) => {
  const hostId = required(d.hostId);
  const now = Date.now();
  let result;
  await transact(db().ref(), root => {
    result = updateWeatherSettings(root, uid, hostId, d, now);
  });
  return result;
});
export const setReminderSettings = callable(async (uid, d) => {
  const hostId = required(d.hostId);
  const now = Date.now();
  let result;
  await transact(db().ref(), root => {
    result = updateReminderSettings(root, uid, hostId, d, now);
  });
  return result;
});
export const setReminderPlan = callable(async (uid, d) => {
  const hostId = required(d.hostId);
  const now = Date.now();
  let result;
  await transact(db().ref(), root => {
    result = reminderPlan.setReminderPlan(root, uid, hostId, d, now, () => `r-${randomUUID().slice(0, 12)}`);
  });
  return result;
}, [], {minInstances: 0, maxInstances: 1});
function reminderBucket() {
  const name = STORAGE_BUCKET.value();
  if (!name || !/^[a-z0-9][a-z0-9.-]{1,220}[a-z0-9]$/.test(name)) throw new HttpsError('failed-precondition', '語音服務尚未完成設定');
  return getStorage().bucket(name);
}
export const uploadReminderVoice = callable(async (uid, d) => {
  const hostId = required(d.hostId);
  const voice = decodeVoice(d.audioBase64);
  const id = `v-${randomUUID().slice(0, 12)}`;
  const core = (await db().ref('core').get()).val() || {};
  let reserved;
  await transact(db().ref(`care/${hostId}/reminderVoices`), voices => {
    reserved = reminderPlan.reserveReminderVoice(core, voices, uid, hostId, id,
      {durationMs: d.durationMs, sha256: voice.sha256}, Date.now());
  });
  try {
    await reminderBucket().file(reserved.objectPath).save(voice.bytes, {resumable: false,
      preconditionOpts: {ifGenerationMatch: 0}, metadata: {contentType: 'audio/mp4', cacheControl: 'private, no-store'}});
  } catch (e) {
    if (e instanceof HttpsError) throw e;
    throw new HttpsError('unavailable', '語音上傳失敗，請再試一次');
  }
  await transact(db().ref(`care/${hostId}/reminderVoices`), voices => {
    reminderPlan.finishReminderVoice(voices, uid, id, Date.now());
  });
  return {voiceId: id, durationMs: reserved.durationMs};
}, [], {minInstances: 0, maxInstances: 1});
export const getReminderVoice = callable(async (uid, d) => {
  const hostId = required(d.hostId), id = required(d.voiceId);
  const core = (await db().ref('core').get()).val() || {};
  const voices = (await db().ref(`care/${hostId}/reminderVoices`).get()).val() || {};
  const v = reminderPlan.readableReminderVoice(core, voices, uid, hostId, id);
  let bytes;
  try { [bytes] = await reminderBucket().file(v.objectPath).download(); }
  catch (e) { if (e instanceof HttpsError) throw e; throw new HttpsError('not-found', '提醒語音已過期，請家人重錄'); }
  if (createHash('sha256').update(bytes).digest('hex') !== v.sha256) throw new HttpsError('data-loss', '語音檔驗證失敗');
  return {voiceId: id, audioBase64: bytes.toString('base64'), durationMs: v.durationMs};
}, [], {minInstances: 0, maxInstances: 1});
export const setVoiceProfile = callable(async (uid, d) => {
  const hostId = required(d.hostId);
  const core = (await db().ref('core').get()).val() || {};
  let result;
  await transact(db().ref(`care/${hostId}`), care => {
    result = reminderPlan.setVoiceProfile(core, care, uid, hostId, d, Date.now());
  });
  return result;
}, [], {minInstances: 0, maxInstances: 1});
export const setHandling = callable(async (uid, d) => {
  const hostId = required(d.hostId);
  const core = (await db().ref('core').get()).val() || {};
  let result;
  await transact(db().ref(`care/${hostId}/handling`), h => { result = handlingTransition(core, h, uid, hostId, d, Date.now()); });
  return result;
}, [], {minInstances: 0, maxInstances: 1});
export const reportReminderStatus = callable(async (uid, d) => {
  const core = (await db().ref('core').get()).val() || {};
  let result;
  await transact(db().ref(`care/${uid}/reminderStatus`), status => {
    result = reminderStatusTransition(core, status, uid, uid, d, Date.now());
  });
  return result;
}, [], {minInstances: 0, maxInstances: 1});
const single = {minInstances: 0, maxInstances: 1};
export const RING_ANNOUNCE_TEXT = '我按了讓你的手機響，看到請回我';
const RING_ANNOUNCE_DELAY_MS = 12_000;
export const setLocationSharing = callable(async (uid, d) => {
  const core = (await db().ref('core').get()).val() || {};
  let result;
  await transact(db().ref(`care/${uid}/location`), loc => {
    result = locationState.setLocationSharing(core, loc, uid, uid, d, Date.now());
  });
  return result;
}, [], single);
export const reportLocation = callable(async (uid, d) => {
  const core = (await db().ref('core').get()).val() || {};
  let result;
  await transact(db().ref(`care/${uid}/location`), loc => {
    result = locationState.reportLocation(core, loc, uid, uid, d, Date.now());
  });
  return result;
}, [], single);
/** Family asks grandma's phone to refresh its location (and app usage). */
export const requestHostUpdate = callable(async (uid, d) => {
  const hostId = required(d.hostId);
  const kind = d.kind === 'usage' ? 'usage' : 'locate';
  const core = (await db().ref('core').get()).val() || {};
  if (kind === 'locate') {
    await transact(db().ref(`care/${hostId}/location`), loc => {
      locationState.requestLocate(core, loc, uid, hostId, Date.now());
    });
  } else {
    reminderPlan.authorizeMember(core, uid, hostId);
    const consent = (await db().ref(`care/${hostId}/appUsage/consent`).get()).val();
    if (!consent?.enabled) throw new HttpsError('failed-precondition', '長輩尚未開啟或已暫停使用時間分享');
    await atomic(s => { model.rate(s, `usage_${uid}`, Date.now(), 6, 60_000); });
  }
  const push = await pushData([hostId], {type: kind, hostId});
  return {ok: true, push};
}, [], single);
export const ringHostPhone = callable(async (uid, d) => {
  const hostId = required(d.hostId);
  const core = (await db().ref('core').get()).val() || {};
  let ring;
  await transact(db().ref(`care/${hostId}/location`), loc => {
    ring = locationState.ringHost(core, loc, uid, hostId, Date.now());
  });
  const push = await pushData([hostId], {type: 'ring', hostId, by: ring.name, seconds: '10'});
  // Grandma's phone reads family messages aloud, so a short message from the
  // person who pressed it tells her who is looking for her. Sent after the
  // ten-second ring so the voice does not talk over the alarm.
  await new Promise(resolve => setTimeout(resolve, RING_ANNOUNCE_DELAY_MS));
  let announced = false;
  try {
    await companionGateway().sendCareMessage(uid, {hostId, text: RING_ANNOUNCE_TEXT});
    announced = true;
  } catch (e) {
    console.warn('Ring announcement not sent', e?.code || 'error');
  }
  return {ok: true, push, announced};
}, [], single);
export const setAppUsageSharing = callable(async (uid, d) => {
  const core = (await db().ref('core').get()).val() || {};
  let result;
  await transact(db().ref(`care/${uid}/appUsage`), usage => {
    result = usageState.setAppUsageSharing(core, usage, uid, uid, d, Date.now());
  });
  return result;
}, [], single);
export const reportAppUsage = callable(async (uid, d) => {
  const core = (await db().ref('core').get()).val() || {};
  let result;
  await transact(db().ref(`care/${uid}/appUsage`), usage => {
    result = usageState.reportAppUsage(core, usage, uid, uid, d, Date.now());
  });
  return {date: d.date, total: result.total};
}, [], single);
/** Own display name and optional photo. Photos live outside /core so the
 * pairing transaction never carries image data.
 */
export const setProfile = callable(async (uid, d) => {
  const now = Date.now();
  const name = d.name == null ? null : profileState.cleanName(d.name);
  const avatar = d.avatarBase64 == null ? null : profileState.cleanAvatar(d.avatarBase64);
  let hostId = null;
  await atomic(s => {
    model.rate(s, `profile_${uid}`, now, 10, 60 * 60_000);
    if (!s.devices?.[uid]) throw new HttpsError('failed-precondition', '未註冊裝置');
    hostId = s.devices[uid].role === 'host' ? uid : s.links?.[uid]?.hostId || null;
    if (name) profileState.setProfileName(s, uid, name, now);
  });
  if (hostId && (avatar || d.removeAvatar === true)) {
    await db().ref(`avatars/${hostId}/${uid}`).set(avatar ? {jpegBase64: avatar, updatedAt: now} : null);
  }
  return {ok: true, hostId, name};
}, [], single);
export const setPlaceAlerts = callable(async (uid, d) => {
  const core = (await db().ref('core').get()).val() || {};
  let result;
  await transact(db().ref(`care/${uid}/places`), places => {
    result = placeAlerts.setPlaceAlerts(core, places, uid, uid, d, Date.now());
  });
  return result;
}, [], {minInstances: 0, maxInstances: 1});
export const reportPlaceEvent = callable(async (uid, d) => {
  const core = (await db().ref('core').get()).val() || {};
  const id = randomUUID();
  let event;
  await transact(db().ref(`care/${uid}/places`), places => {
    event = placeAlerts.reportPlaceEvent(core, places, uid, uid, d, Date.now(), id);
  });
  if (!event) return {ok: true, duplicate: true};
  const members = Object.keys(core.families?.[uid]?.members || {});
  const workName = (await db().ref(`care/${uid}/places/consent/workName`).get()).val() || '工作地點';
  const message = placeAlerts.placeMessage(event, workName, model.hostName(core, uid));
  const push = await (async () => {
    try { return await pushPlace(members, message.title, message.body, {type: 'place', hostId: uid}); }
    catch { return {accepted: 0, failed: members.length}; }
  })();
  return {ok: true, push};
}, [], {minInstances: 0, maxInstances: 1});
const pushPlace = (uids, title, body, data) => push(uids, title, body, data);
export const reportBatterySample = callable(async (uid, d) => batteryGateway().reportBatterySample(uid, d));
export const ackBatteryEvent = callable(async (uid, d) => batteryGateway().ackBatteryEvent(uid, d));
export const setBatteryNotificationPreference = callable(async (uid, d) =>
  batteryGateway().setBatteryNotificationPreference(uid, d));
// Companion callables are capped at one instance to bound cost.
const companionOptions = {minInstances: 0, maxInstances: 1};
export const setCompanionConsent = callable(async (uid, d) => companionGateway().setCompanionConsent(uid, d), [], companionOptions);
export const recordReminderResponse = callable(async (uid, d) => companionGateway().recordReminderResponse(uid, d), [], companionOptions);
export const recordMood = callable(async (uid, d) => companionGateway().recordMood(uid, d), [], companionOptions);
export const reportSoundStatus = callable(async (uid, d) => companionGateway().reportSoundStatus(uid, d), [], companionOptions);
export const sendCareMessage = callable(async (uid, d) => companionGateway().sendCareMessage(uid, d), [], companionOptions);
export const getVoiceMessage = callable(async (uid, d) => companionGateway().getVoiceMessage(uid, d), [], companionOptions);
export const reactToPhoto = callable(async (uid, d) => companionGateway().reactToPhoto(uid, d), [], companionOptions);
export const careMaintenance = onSchedule({region, schedule: 'every 30 minutes', maxInstances: 1}, async () => {
  const families = (await db().ref('core/families').get()).val() || {};
  const summary = await companionGateway().maintenance(Object.keys(families));
  const name = STORAGE_BUCKET.value();
  for (const hostId of Object.keys(families)) {
    const care = (await db().ref(`care/${hostId}`).get()).val() || {};
    for (const item of reminderPlan.unusedReminderVoices(care, Date.now()).slice(0, 50)) {
      try {
        if (name) { try { await getStorage().bucket(name).file(item.objectPath).delete(); } catch (e) { if (Number(e?.code) !== 404) throw e; } }
        await db().ref(`care/${hostId}/reminderVoices/${item.id}`).remove();
      } catch { summary.voiceFailed++; }
    }
  }
  // Location sharing on but no position for hours: tell the family once.
  const core = (await db().ref('core').get()).val() || {};
  for (const hostId of Object.keys(families)) {
    const care = (await db().ref(`care/${hostId}`).get()).val() || {};
    const stale = digest.locationStale(model.hostName(core, hostId), care, Date.now());
    if (!stale) continue;
    await db().ref(`care/${hostId}/location/staleNotified`).set(stale.episode);
    await push(Object.keys(families[hostId]?.members || {}), stale.title, stale.body, {type: 'locationStale', hostId});
  }
  // Photos of family members who were unpaired are removed.
  const avatars = (await db().ref('avatars').get()).val() || {};
  for (const [hostId, byUid] of Object.entries(avatars)) {
    for (const uid of Object.keys(byUid || {})) {
      if (uid !== hostId && !families[hostId]?.members?.[uid]) await db().ref(`avatars/${hostId}/${uid}`).remove();
    }
  }
  console.info('Companion maintenance summary', summary);
  if (summary.voiceFailed) throw new Error('Voice cleanup incomplete');
});
/** 09:00 holiday greeting read aloud on grandma's phone, 12:00 "barely used
 * the phone" check, 20:00 daily summary for the family. Each runs once per
 * day per family; a marker prevents repeats if the job is retried.
 */
export const careDaily = onSchedule({region, schedule: '0 9,12,20 * * *', timeZone: 'Asia/Taipei',
  maxInstances: 1}, async () => {
  const now = Date.now();
  const day = reminderPlan.taipeiDay(now);
  const hour = new Date(now + 8 * 3600_000).getUTCHours();
  const kind = hour < 11 ? 'greeting' : hour < 16 ? 'noon' : 'summary';
  const core = (await db().ref('core').get()).val() || {};
  for (const [hostId, family] of Object.entries(core.families || {})) {
    const members = Object.keys(family?.members || {});
    if (!members.length) continue;
    const marker = db().ref(`care/${hostId}/digest/${kind}/${day}`);
    if ((await marker.get()).exists()) continue;
    const name = model.hostName(core, hostId);
    try {
      if (kind === 'greeting') {
        const line = digest.holidayGreeting(name, day);
        const from = digest.pickGreeter(members, day);
        if (line && from) await companionGateway().announceToHost(from, hostId, line);
      } else {
        const care = (await db().ref(`care/${hostId}`).get()).val() || {};
        const note = kind === 'noon' ? digest.noonCheck(name, care, day) : digest.dailySummary(name, care, day);
        if (note) await push(members, note.title, note.body, {type: kind === 'noon' ? 'noonCheck' : 'summary', hostId});
      }
      await marker.set(now);
    } catch (e) {
      console.warn('careDaily step failed', kind, e?.code || 'error');
    }
  }
  // Markers older than a week are removed.
  const oldest = reminderPlan.taipeiDay(now - 7 * 24 * 3600_000);
  for (const hostId of Object.keys(core.families || {})) {
    const all = (await db().ref(`care/${hostId}/digest`).get()).val() || {};
    for (const [k, days] of Object.entries(all)) {
      for (const d of Object.keys(days || {})) if (d < oldest) await db().ref(`care/${hostId}/digest/${k}/${d}`).remove();
    }
  }
});
// Withdrawal must keep working even when Storage configuration is broken.
export const setPhotoConsent = callable(async (uid, d) => {
  if (d.enabled === true) photoGateway();
  const s = await atomic(current => photoState.setPhotoConsent(current, uid, d.enabled, Date.now()));
  return s.families[uid].photoConsent;
}, [], {minInstances: 0, maxInstances: 1});
export const revokePhotoConsent = callable(async uid => {
  const s = await atomic(current => photoState.revokePhotoConsent(current, uid, Date.now()));
  return s.families[uid].photoConsent;
}, [], {minInstances: 0, maxInstances: 1});
export const uploadCarePhoto = callable(async (uid, d) => photoGateway().upload(uid, d), [], {minInstances: 0, maxInstances: 1});
export const getCarePhoto = callable(async (uid, d) => photoGateway().get(uid, d), [], {minInstances: 0, maxInstances: 1});
export const listCarePhotos = callable(async (uid, d) => ({photos: await photoGateway().list(uid, d)}), [], {minInstances: 0, maxInstances: 1});
export const cleanup = onSchedule({region, schedule: 'every 6 hours', maxInstances: 1}, async () => {
  const now = Date.now();
  const current = (await db().ref('core').get()).val() || {};
  if (model.needsCleanup(current, now)) await atomic(s => {
    for (const [key, v] of Object.entries(s.pairCodes || {})) if (v.expiresAt <= now) delete s.pairCodes[key];
    for (const [key, v] of Object.entries(s.rates || {})) if (v.until <= now) delete s.rates[key];
    for (const [key, v] of Object.entries(s.sessions || {})) {
      if (!model.live(v, now)) {
        if (s.families?.[v.hostId]?.activeSessionId === key) delete s.families[v.hostId].activeSessionId;
        if (['pending', 'ringing', 'accepted'].includes(v.status)) v.status = 'expired';
        if (now - v.createdAt > 24 * 60 * 60_000) delete s.sessions[key];
      }
    }
    for (const f of Object.values(s.families || {})) for (const [key, v] of Object.entries(f.alerts || {})) if (now - v.createdAt > 7 * 24 * 60 * 60_000) delete f.alerts[key];
  });
  const signals = (await db().ref('signals').get()).val() || {};
  for (const id of Object.keys(signals)) {
    const v = (await db().ref(`core/sessions/${id}`).get()).val();
    if (!model.live(v, now)) await db().ref(`signals/${id}`).remove();
  }
  const batterySummary = await runBatteryCleanup({
    hostIds: Object.keys(current.families || {}),
    readBattery: async hostId => (await db().ref(`care/${hostId}/battery`).get()).val() || {},
    transactBattery,
    now,
  });
  console.info('Battery cleanup summary', batterySummary);
  if (STORAGE_BUCKET.value()) {
    await runPhotoCleanup(photoGateway(), summary => console.info('Photo cleanup summary', summary));
  } else if (photoState.photoCleanupCandidates(current, now).length) {
    throw new Error('Photo cleanup requires FAMILYHELPER_STORAGE_BUCKET');
  }
});
