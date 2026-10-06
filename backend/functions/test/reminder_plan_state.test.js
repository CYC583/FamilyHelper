// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as plan from '../src/reminder_plan_state.js';

const NOW = Date.UTC(2026, 9, 3, 2); // 10:00 Taipei, 2026-10-03
const root = () => ({core: {devices: {grandma: {role: 'host'}, alice: {role: 'client', name: '小明'}, eve: {role: 'client'}},
  families: {grandma: {members: {alice: {}}}}, links: {alice: {hostId: 'grandma'}}},
care: {grandma: {reminderVoices: {v1: {status: 'ready'}, v2: {status: 'pending'}}}}});
let n = 0;
const newId = () => `r${++n}`;

test('family adds daily and one-off reminders with text or a ready voice', () => {
  const r = root();
  const saved = plan.setReminderPlan(r, 'alice', 'grandma', {expectedVersion: 0, items: [
    {type: 'medicine', repeat: 'daily', time: '08:00', text: '吃血壓藥'},
    {type: 'custom', repeat: 'once', date: '2026-10-05', time: '15:30', text: '', voiceId: 'v1'},
  ]}, NOW, newId);
  assert.equal(saved.version, 1);
  assert.equal(saved.items.length, 2);
  assert.equal(saved.items[0].author, '小明');
  assert.equal(saved.items[1].voiceId, 'v1');
  assert.equal(saved.items[1].date, '2026-10-05');
});

test('edit keeps the id and author; delete is saving without the row; version guards races', () => {
  const r = root();
  const first = plan.setReminderPlan(r, 'alice', 'grandma', {expectedVersion: 0,
    items: [{type: 'water', time: '14:00', text: '喝水'}]}, NOW, newId);
  const id = first.items[0].id;
  const edited = plan.setReminderPlan(r, 'alice', 'grandma', {expectedVersion: 1,
    items: [{id, type: 'water', time: '15:00', text: '喝杯水'}]}, NOW + 1, newId);
  assert.equal(edited.items[0].id, id);
  assert.equal(edited.items[0].time, '15:00');
  assert.throws(() => plan.setReminderPlan(r, 'alice', 'grandma', {expectedVersion: 1, items: []}, NOW, newId),
    {code: 'aborted'});
  assert.equal(plan.setReminderPlan(r, 'alice', 'grandma', {expectedVersion: 2, items: []}, NOW, newId).items.length, 0);
});

test('rejects outsiders, bad times, past or bad dates, pending voices, empty custom and too many rows', () => {
  for (const [uid, items] of [
    ['eve', []], ['grandma', []],
    ['alice', [{type: 'water', time: '25:00', text: 'x'}]],
    ['alice', [{type: 'custom', repeat: 'once', date: '2026-02-30', time: '08:00', text: 'x'}]],
    ['alice', [{type: 'custom', time: '08:00', text: '', voiceId: 'v2'}]],
    ['alice', [{type: 'custom', time: '08:00', text: ''}]],
    ['alice', [{type: 'sos', time: '08:00', text: 'x'}]],
    ['alice', Array.from({length: 31}, () => ({type: 'water', time: '08:00', text: 'x'}))],
  ]) {
    assert.throws(() => plan.setReminderPlan(root(), uid, 'grandma', {expectedVersion: 0, items}, NOW, newId));
  }
  const past = plan.setReminderPlan(root(), 'alice', 'grandma', {expectedVersion: 0,
    items: [{type: 'custom', repeat: 'once', date: '2026-10-02', time: '08:00', text: '昨天'}]}, NOW, newId);
  assert.equal(past.items.length, 0, 'past one-off reminders are dropped');
});

test('reminder voices: reserve, finish, read by host/member, unused ones expire', () => {
  const r = root();
  const voices = {};
  plan.reserveReminderVoice(r.core, voices, 'alice', 'grandma', 'v9', {durationMs: 5000, sha256: 'a'.repeat(64)}, NOW);
  assert.throws(() => plan.readableReminderVoice(r.core, voices, 'grandma', 'grandma', 'v9'), {code: 'not-found'});
  plan.finishReminderVoice(voices, 'alice', 'v9', NOW + 1);
  assert.equal(plan.readableReminderVoice(r.core, voices, 'grandma', 'grandma', 'v9').status, 'ready');
  assert.throws(() => plan.readableReminderVoice(r.core, voices, 'eve', 'grandma', 'v9'));
  const care = {settings: {reminderPlan: {items: [{voiceId: 'keep'}]}},
    reminderVoices: {keep: {createdAt: 0}, old: {createdAt: 0, objectPath: 'p'}, fresh: {createdAt: NOW}}};
  assert.deepEqual(plan.unusedReminderVoices(care, NOW).map(v => v.id), ['old']);
});

test('a member sets their own intro clip and joins the weather rotation', () => {
  const r = root();
  r.care.grandma.reminderVoices.mine = {status: 'ready', createdBy: 'alice'};
  r.care.grandma.reminderVoices.theirs = {status: 'ready', createdBy: 'bob'};
  const care = r.care.grandma;
  const saved = plan.setVoiceProfile(r.core, care, 'alice', 'grandma', {introVoiceId: 'mine', joinWeather: true}, NOW);
  assert.deepEqual(saved, {name: '小明', joinWeather: true, introVoiceId: 'mine', updatedAt: NOW});
  assert.throws(() => plan.setVoiceProfile(r.core, care, 'alice', 'grandma', {introVoiceId: 'theirs', joinWeather: true}, NOW));
  assert.throws(() => plan.setVoiceProfile(r.core, care, 'eve', 'grandma', {joinWeather: false}, NOW));
  assert.equal(plan.setVoiceProfile(r.core, care, 'alice', 'grandma', {joinWeather: true}, NOW).joinWeather, false,
    'no intro clip means no rotation slot');
  care.voiceProfiles.alice.introVoiceId = 'mine';
  assert.equal(plan.unusedReminderVoices({...care, reminderVoices: {mine: {createdAt: 0}}}, NOW).length, 0);
});

test('weekly days, pause until a date, and who last edited', () => {
  const r = root();
  r.core.devices.bob = {role: 'client', name: '哥哥'};
  r.core.families.grandma.members.bob = {};
  r.core.links.bob = {hostId: 'grandma'};
  const first = plan.setReminderPlan(r, 'alice', 'grandma', {expectedVersion: 0, items: [
    {type: 'custom', repeat: 'weekly', days: [4, 2, 2], time: '09:00', text: '帶健保卡'},
  ]}, NOW, newId);
  assert.deepEqual(first.items[0].days, [2, 4]);
  assert.equal(first.items[0].editedBy, '小明');
  const id = first.items[0].id;
  const paused = plan.setReminderPlan(r, 'bob', 'grandma', {expectedVersion: 1, items: [
    {id, type: 'custom', repeat: 'weekly', days: [2, 4], time: '09:00', text: '帶健保卡', pausedUntil: '2026-10-10'},
  ]}, NOW + 1, newId);
  assert.equal(paused.items[0].pausedUntil, '2026-10-10');
  assert.equal(paused.items[0].editedBy, '哥哥');
  assert.equal(paused.items[0].author, '小明', 'creator unchanged');
  assert.throws(() => plan.setReminderPlan(r, 'bob', 'grandma', {expectedVersion: 2, items: [
    {type: 'water', repeat: 'weekly', days: [], time: '09:00', text: 'x'}]}, NOW, newId));
});
