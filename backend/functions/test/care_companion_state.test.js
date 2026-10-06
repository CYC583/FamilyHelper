// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as care from '../src/care_companion_state.js';

const NOW = Date.UTC(2026, 9, 2, 2, 0); // 10:00 Taipei
function core() {
  return {devices: {grandma: {role: 'host'}, alice: {role: 'client'}, bob: {role: 'client'},
    outsider: {role: 'client'}},
  families: {grandma: {members: {alice: {name: 'A'}, bob: {name: 'B'}},
    photoConsent: {enabled: true, version: 3, shareGeneration: 1}}},
  links: {alice: {hostId: 'grandma'}, bob: {hostId: 'grandma'}},
  photoOps: {grandma: {op1: {mediaId: 'm1', authorId: 'grandma', status: 'ready', shareGeneration: 1,
    expiresAt: NOW + 1000_000, createdAt: NOW - 1000, day: '2026-10-02'}}}};
}
const enable = {action: 'enable', items: {responses: true, mood: true, sound: false},
  disclosureVersion: care.COMPANION_DISCLOSURE_VERSION};

test('only the host can enable itemised companion sharing; family cannot consent for her', () => {
  const companion = {};
  assert.throws(() => care.setCompanionConsent(core(), companion, 'alice', 'grandma', enable, NOW),
    {code: 'permission-denied'});
  assert.throws(() => care.setCompanionConsent(core(), companion, 'grandma', 'grandma',
    {...enable, disclosureVersion: 0}, NOW), {code: 'failed-precondition'});
  const consent = care.setCompanionConsent(core(), companion, 'grandma', 'grandma', enable, NOW);
  assert.deepEqual(consent.items, {responses: true, mood: true, sound: false});
  assert.equal(consent.status, 'enabled');
  assert.equal(consent.version, 1);
  const paused = care.setCompanionConsent(core(), companion, 'grandma', 'grandma', {action: 'pause'}, NOW + 1);
  assert.equal(paused.enabled, false);
  assert.equal(paused.status, 'paused');
  assert.equal(paused.version, 2);
});

test('revoking deletes shared replies, mood and sound so a later grant does not resurrect them', () => {
  const companion = {};
  care.setCompanionConsent(core(), companion, 'grandma', 'grandma', {...enable,
    items: {responses: true, mood: true, sound: true}}, NOW);
  care.recordReminderResponse(core(), companion, 'grandma', 'grandma', {date: '2026-10-02',
    type: 'medicine', time: '08:00', response: 'done', consentVersion: 1}, NOW);
  care.recordMood(core(), companion, 'grandma', 'grandma', {date: '2026-10-02', mood: 'good',
    consentVersion: 1}, NOW);
  care.setCompanionConsent(core(), companion, 'grandma', 'grandma', {action: 'revoke'}, NOW + 5);
  assert.equal(companion.responses, undefined);
  assert.equal(companion.mood, undefined);
  assert.equal(companion.sound, undefined);
  assert.equal(companion.consent.status, 'revoked');
});

test('reminder replies are host-only, need the responses item and current consent version', () => {
  const companion = {};
  const reply = {date: '2026-10-02', type: 'medicine', time: '08:00', response: 'done', consentVersion: 1};
  assert.throws(() => care.recordReminderResponse(core(), companion, 'grandma', 'grandma', reply, NOW),
    {code: 'failed-precondition'});
  care.setCompanionConsent(core(), companion, 'grandma', 'grandma', enable, NOW);
  assert.throws(() => care.recordReminderResponse(core(), companion, 'alice', 'grandma', reply, NOW),
    {code: 'permission-denied'});
  assert.throws(() => care.recordReminderResponse(core(), companion, 'grandma', 'grandma',
    {...reply, consentVersion: 9}, NOW), {code: 'failed-precondition'});
  const saved = care.recordReminderResponse(core(), companion, 'grandma', 'grandma', reply, NOW);
  assert.deepEqual(Object.keys(saved).sort(), ['receivedAt', 'respondedAt', 'response', 'time', 'type']);
  assert.equal(companion.responses['2026-10-02'].medicine_0800.response, 'done');
  for (const bad of [{response: 'took-two-pills'}, {type: 'sos'}, {time: '8:00'},
    {date: '2026-13-40'}, {date: '2026-09-01'}, {text: '阿斯匹靈'}]) {
    assert.throws(() => care.recordReminderResponse(core(), companion, 'grandma', 'grandma',
      {...reply, ...bad}, NOW));
  }
});

test('mood requires its own item; sound sharing stays off when only replies were accepted', () => {
  const companion = {};
  care.setCompanionConsent(core(), companion, 'grandma', 'grandma',
    {...enable, items: {responses: true, mood: false, sound: false}}, NOW);
  assert.throws(() => care.recordMood(core(), companion, 'grandma', 'grandma',
    {date: '2026-10-02', mood: 'good', consentVersion: 1}, NOW), {code: 'failed-precondition'});
  assert.throws(() => care.reportSoundStatus(core(), companion, 'grandma', 'grandma',
    {ringer: 'silent', dnd: false, mediaZero: false, observedAt: NOW, consentVersion: 1}, NOW),
  {code: 'failed-precondition'});
});

test('sound alert is raised once only after one hour of continuous silence and resolves later', () => {
  const companion = {};
  care.setCompanionConsent(core(), companion, 'grandma', 'grandma',
    {...enable, items: {responses: false, mood: false, sound: true}}, NOW);
  const report = (at, ringer = 'silent') => care.reportSoundStatus(core(), companion, 'grandma', 'grandma',
    {ringer, dnd: false, mediaZero: false, observedAt: at, consentVersion: 1}, at);
  assert.equal(report(NOW).notify, null);
  assert.equal(report(NOW + 30 * 60_000).notify, null);
  const raised = report(NOW + 61 * 60_000);
  assert.equal(raised.notify?.type, 'sound');
  assert.equal(report(NOW + 90 * 60_000).notify, null, 'deduplicated within one episode');
  assert.equal(report(NOW + 95 * 60_000, 'normal').notify, null);
  assert.equal(companion.sound.episode, undefined);
  assert.equal(companion.sound.latest.ringer, 'normal');
});

test('text messages are bounded, from host or current family, with a daily quota', () => {
  const items = {};
  assert.throws(() => care.addMessage(core(), items, 'outsider', 'grandma',
    {kind: 'text', text: 'hi'}, NOW, 'x1'), {code: 'permission-denied'});
  for (const text of ['', ' ', 'a'.repeat(81), '<b>hi</b>']) {
    assert.throws(() => care.addMessage(core(), items, 'alice', 'grandma', {kind: 'text', text}, NOW, 'x2'));
  }
  const saved = care.addMessage(core(), items, 'alice', 'grandma', {kind: 'text', text: ' 長輩早安 '}, NOW, 'x3');
  assert.equal(saved.text, '長輩早安');
  assert.equal(saved.expiresAt, NOW + care.MEDIA_TTL_MS);
  for (let i = 0; i < care.TEXT_DAILY_LIMIT - 1; i++) {
    care.addMessage(core(), items, 'alice', 'grandma', {kind: 'text', text: `第${i}則`}, NOW, `y${i}`);
  }
  assert.throws(() => care.addMessage(core(), items, 'alice', 'grandma', {kind: 'text', text: 'more'}, NOW, 'z'),
    {code: 'resource-exhausted'});
  care.addMessage(core(), items, 'grandma', 'grandma', {kind: 'text', text: '收到'}, NOW, 'g1');
});

test('voice notes are limited to 30 seconds; daily count has only a runaway ceiling', () => {
  const items = {};
  const voice = {kind: 'voice', durationMs: 12_000, sha256: 'a'.repeat(64)};
  assert.throws(() => care.addMessage(core(), items, 'alice', 'grandma', {...voice, durationMs: 31_000}, NOW, 'v0'));
  for (let i = 1; i <= care.VOICE_DAILY_LIMIT; i++) care.addMessage(core(), items, 'alice', 'grandma', voice, NOW, `v${i}`);
  assert.ok(care.VOICE_DAILY_LIMIT >= 500, 'family use is effectively unlimited');
  assert.throws(() => care.addMessage(core(), items, 'alice', 'grandma', voice, NOW, 'over'),
    {code: 'resource-exhausted'});
  care.addMessage(core(), items, 'alice', 'grandma', voice, NOW + 24 * 60 * 60_000, 'next-day');
  assert.equal(items.v1.objectPath, 'care-voice/grandma/v1.m4a');
});

test('message reads are refused after unpair and past expiry', () => {
  const items = {};
  care.addMessage(core(), items, 'alice', 'grandma', {kind: 'voice', durationMs: 5000, sha256: 'b'.repeat(64)}, NOW, 'v1');
  assert.throws(() => care.readableMessage(core(), items, 'bob', 'grandma', 'v1', NOW), {code: 'not-found'},
    'pending upload is never listed as playable');
  assert.throws(() => care.finalizeVoice(core(), items, 'bob', 'grandma', 'v1', NOW), {code: 'failed-precondition'});
  care.finalizeVoice(core(), items, 'alice', 'grandma', 'v1', NOW + 1000);
  assert.equal(care.readableMessage(core(), items, 'bob', 'grandma', 'v1', NOW).objectPath,
    'care-voice/grandma/v1.m4a');
  const unpaired = core();
  delete unpaired.families.grandma.members.alice; delete unpaired.links.alice;
  assert.throws(() => care.readableMessage(unpaired, items, 'bob', 'grandma', 'v1', NOW), {code: 'not-found'},
    'author removed: no longer readable');
  assert.throws(() => care.readableMessage(core(), items, 'bob', 'grandma', 'v1', NOW + care.MEDIA_TTL_MS),
    {code: 'not-found'});
});

test('photo hearts and comments need a currently visible photo and photo consent', () => {
  const reactions = {};
  const saved = care.reactToPhoto(core(), reactions, 'alice', 'grandma',
    {mediaId: 'm1', heart: true, comment: '好漂亮'}, NOW);
  assert.equal(saved.heart, true);
  assert.equal(reactions.m1.alice.comment, '好漂亮');
  assert.throws(() => care.reactToPhoto(core(), reactions, 'alice', 'grandma',
    {mediaId: 'missing', heart: true}, NOW), {code: 'not-found'});
  const paused = core();
  paused.families.grandma.photoConsent.enabled = false;
  assert.throws(() => care.reactToPhoto(paused, reactions, 'alice', 'grandma',
    {mediaId: 'm1', heart: true}, NOW), {code: 'failed-precondition'});
  assert.throws(() => care.reactToPhoto(core(), reactions, 'alice', 'grandma',
    {mediaId: 'm1', heart: true, comment: 'x'.repeat(61)}, NOW));
});

test('liveness sweep raises one suspected-offline event per outage and resolves on a new report', () => {
  const battery = {consent: {enabled: true, status: 'enabled', disclosureVersion: 2, updatedAt: NOW - 10 * 3600_000},
    latest: {receivedAt: NOW - 4 * 3600_000}};
  const companion = {};
  const first = care.livenessStep(battery, companion, NOW);
  assert.equal(first.notify, true);
  assert.equal(companion.liveness.state, 'suspected');
  assert.equal(care.livenessStep(battery, companion, NOW + 1800_000).notify, false);
  battery.latest.receivedAt = NOW + 3600_000;
  assert.equal(care.livenessStep(battery, companion, NOW + 3600_000 + 1).notify, false);
  assert.equal(companion.liveness.state, 'resolved');
  battery.consent = {enabled: false, status: 'paused', updatedAt: NOW};
  battery.latest.receivedAt = NOW - 99 * 3600_000;
  assert.equal(care.livenessStep(battery, companion, NOW + 9 * 3600_000).notify, false,
    'paused sharing is never reported as offline');
});

test('cleanup drops expired days, messages and reactions for photos no longer visible', () => {
  const careHost = {
    companion: {responses: {'2026-08-01': {a: 1}, '2026-10-01': {b: 1}}, mood: {'2026-08-01': {}, '2026-10-02': {}}},
    messages: {items: {old: {authorId: 'alice', createdAt: 1, expiresAt: NOW - 1},
      gone: {authorId: 'ghost', createdAt: NOW, expiresAt: NOW + 1000}, ok: {authorId: 'bob', createdAt: NOW, expiresAt: NOW + 1000}}},
    photoReactions: {m1: {alice: {heart: true}, ghost: {heart: true}}, mX: {alice: {heart: true}}},
  };
  const removed = care.companionCleanup(core(), careHost, NOW);
  assert.deepEqual(Object.keys(careHost.companion.responses), ['2026-10-01']);
  assert.deepEqual(Object.keys(careHost.companion.mood), ['2026-10-02']);
  assert.deepEqual(Object.keys(careHost.messages.items), ['ok']);
  assert.deepEqual(Object.keys(careHost.photoReactions), ['m1']);
  assert.deepEqual(Object.keys(careHost.photoReactions.m1), ['alice']);
  assert.deepEqual(removed.voiceObjects, []);
});
