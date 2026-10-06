// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import {createHash, randomUUID} from 'node:crypto';
import {Fault, hostName} from './state.js';
import * as care from './care_companion_state.js';

const MAX_VOICE_BYTES = 400_000;
const MAX_CLEANUP_OBJECTS = 100;

function requiredId(value, label = '識別碼') {
  if (typeof value !== 'string' || !/^[a-zA-Z0-9-]{1,128}$/.test(value)) {
    throw new Fault('invalid-argument', `${label}無效`);
  }
  return value;
}

/** Accept only an MP4/AAC container (Android MediaRecorder MPEG_4 + AAC). */
export function decodeVoice(base64) {
  if (typeof base64 !== 'string' || base64.length > Math.ceil(MAX_VOICE_BYTES / 3) * 4 + 4 ||
      !/^[A-Za-z0-9+/]+={0,2}$/.test(base64)) {
    throw new Fault('invalid-argument', '語音檔格式錯誤或太大');
  }
  const bytes = Buffer.from(base64, 'base64');
  if (bytes.length < 64 || bytes.length > MAX_VOICE_BYTES || bytes.toString('latin1', 4, 8) !== 'ftyp') {
    throw new Fault('invalid-argument', '語音檔格式錯誤或太大');
  }
  return {bytes, sha256: createHash('sha256').update(bytes).digest('hex')};
}

const GENERIC_MESSAGE = {title: '家人傳來新留言', body: '請開啟 FamilyHelper 查看。'};

/**
 * readCore: () => current /core. transactCare(hostId, child, update) runs
 * update(current) on /care/{hostId}/{child} and returns the committed value.
 * notify(uids, title, body, data) attempts FCM; acceptance is not delivery.
 */
export function createCompanionGateway({readCore, transactCare, readCare, bucket, notify,
  now = Date.now, newId = randomUUID}) {
  async function inTx(hostId, child, fn) {
    let result;
    const core = await readCore();
    await transactCare(hostId, child, current => { result = fn(core, current); });
    return {core, result};
  }
  const recipients = (core, hostId, except) => [hostId, ...Object.keys(core.families?.[hostId]?.members || {})]
    .filter(uid => uid !== except);

  function bucketOrFail() {
    if (!bucket) throw new Fault('failed-precondition', '語音服務尚未完成設定');
    return bucket;
  }

  return {
    async setCompanionConsent(uid, d) {
      return (await inTx(uid, 'companion', (core, c) => care.setCompanionConsent(core, c, uid, uid, d, now()))).result;
    },
    async recordReminderResponse(uid, d) {
      return (await inTx(uid, 'companion', (core, c) => care.recordReminderResponse(core, c, uid, uid, d, now()))).result;
    },
    async recordMood(uid, d) {
      return (await inTx(uid, 'companion', (core, c) => care.recordMood(core, c, uid, uid, d, now()))).result;
    },
    async reportSoundStatus(uid, d) {
      const {core, result} = await inTx(uid, 'companion', (core, c) => care.reportSoundStatus(core, c, uid, uid, d, now()));
      let push = null;
      if (result.notify) {
        const name = hostName(core, uid);
        push = await notify(recipients(core, uid, uid), `${name}的手機可能沒有聲音`,
          `${name}的手機已靜音或勿擾超過一小時，請開啟 App 查看。`, {type: 'sound', hostId: uid,
            eventId: result.notify.eventId});
      }
      return {ok: true, notified: !!result.notify, push};
    },
    async sendCareMessage(uid, d) {
      const hostId = requiredId(d?.hostId, '長輩識別碼');
      const id = newId();
      if (d?.kind === 'voice') {
        const voice = decodeVoice(d.audioBase64);
        const {result} = await inTx(hostId, 'messages/items', (core, items) => care.addMessage(core, items, uid, hostId,
          {kind: 'voice', durationMs: d.durationMs, sha256: voice.sha256}, now(), id));
        try {
          await bucketOrFail().file(result.objectPath).save(voice.bytes, {
            resumable: false, preconditionOpts: {ifGenerationMatch: 0},
            metadata: {contentType: 'audio/mp4', cacheControl: 'private, no-store'},
          });
        } catch (error) {
          // Leave the pending row for cleanup; never report a playable note.
          throw error instanceof Fault ? error : new Fault('unavailable', '語音上傳失敗，請稍後重試');
        }
        const done = await inTx(hostId, 'messages/items', (core, items) =>
          care.finalizeVoice(core, items, uid, hostId, id, now()));
        await notify(recipients(done.core, hostId, uid), GENERIC_MESSAGE.title, GENERIC_MESSAGE.body,
          {type: 'message', hostId});
        return {id, kind: 'voice', createdAt: done.result.createdAt};
      }
      const {core, result} = await inTx(hostId, 'messages/items', (core, items) =>
        care.addMessage(core, items, uid, hostId, {kind: 'text', text: d?.text}, now(), id));
      await notify(recipients(core, hostId, uid), GENERIC_MESSAGE.title, GENERIC_MESSAGE.body, {type: 'message', hostId});
      return {id, kind: 'text', createdAt: result.createdAt};
    },
    async getVoiceMessage(uid, d) {
      const hostId = requiredId(d?.hostId, '長輩識別碼');
      const id = requiredId(d?.id, '留言識別碼');
      const items = (await readCare(hostId, 'messages/items')) || {};
      const item = care.readableMessage(await readCore(), items, uid, hostId, id, now());
      let bytes;
      try { [bytes] = await bucketOrFail().file(item.objectPath).download(); }
      catch (error) { throw error instanceof Fault ? error : new Fault('failed-precondition', '語音暫時無法播放'); }
      if (!Buffer.isBuffer(bytes) || bytes.length > MAX_VOICE_BYTES ||
          createHash('sha256').update(bytes).digest('hex') !== item.sha256) {
        throw new Fault('data-loss', '語音檔驗證失敗');
      }
      // Re-check after the download so an unpair during the read is honoured.
      care.readableMessage(await readCore(), (await readCare(hostId, 'messages/items')) || {}, uid, hostId, id, now());
      return {id, audioBase64: bytes.toString('base64'), durationMs: item.durationMs};
    },
    async reactToPhoto(uid, d) {
      const hostId = requiredId(d?.hostId, '長輩識別碼');
      let before = null;
      const {core, result} = await inTx(hostId, 'photoReactions', (core, reactions) => {
        before = reactions?.[d?.mediaId]?.[uid] || null;
        return care.reactToPhoto(core, reactions, uid, hostId, d, now());
      });
      if (result.heart || result.comment) {
        await notify(recipients(core, hostId, uid), '家人回應了照片', '請開啟 FamilyHelper 查看。', {type: 'photo', hostId});
      }
      // Grandma's phone reads family messages aloud: tell her who reacted.
      const line = care.photoReactionLine(before, result);
      if (line && uid !== hostId) {
        try { await this.announceToHost(uid, hostId, line); } catch { /* the reaction itself is saved */ }
      }
      return result;
    },
    /** A short text message from a family member that only grandma's phone is
     * told about (it reads it aloud); other family see it in the chat.
     */
    async announceToHost(uid, hostId, text) {
      const id = newId();
      const {result} = await inTx(hostId, 'messages/items', (core, items) =>
        care.addMessage(core, items, uid, hostId, {kind: 'text', text}, now(), id));
      await notify([hostId], GENERIC_MESSAGE.title, GENERIC_MESSAGE.body, {type: 'message', hostId});
      return {id, createdAt: result.createdAt};
    },
    /** Scheduled: retention, orphaned voice objects and suspected offline. */
    async maintenance(hostIds) {
      const summary = {voiceDeleted: 0, voiceFailed: 0, offlineNotified: 0};
      for (const hostId of hostIds) {
        const core = await readCore();
        let objects = [];
        await transactCare(hostId, '', current => {
          objects = care.companionCleanup(core, current, now(), hostId).voiceObjects;
        });
        for (const item of objects.slice(0, MAX_CLEANUP_OBJECTS)) {
          if (!bucket) { summary.voiceFailed++; continue; }
          try {
            try { await bucket.file(item.objectPath).delete(); }
            catch (error) { if (Number(error?.code) !== 404) throw error; }
            summary.voiceDeleted++;
          } catch { summary.voiceFailed++; }
        }
        const battery = (await readCare(hostId, 'battery')) || {};
        let step = {notify: false};
        await transactCare(hostId, 'companion', current => { step = care.livenessStep(battery, current, now()); });
        if (step.notify) {
          const prefs = battery.preferences || {};
          const members = Object.keys(core.families?.[hostId]?.members || {})
            .filter(uid => prefs[uid]?.enabled !== false);
          const name = hostName(core, hostId);
          await notify(members, `${name}的手機疑似離線`, `超過三小時沒有收到${name}手機的回報，請開啟 App 查看並直接聯絡${name}。`,
            {type: 'offline', hostId, eventId: step.eventId});
          summary.offlineNotified++;
        }
      }
      return summary;
    },
  };
}
