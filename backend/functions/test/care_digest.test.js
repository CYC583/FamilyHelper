// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as digest from '../src/care_digest_state.js';
import {photoReactionLine} from '../src/care_companion_state.js';
import {alertPush, hostName} from '../src/state.js';
import {placeMessage} from '../src/place_alert_state.js';

const on = v => ({enabled: true, status: 'enabled', disclosureVersion: v, version: 1});
const day = '2026-10-03';
const at = (hhmm) => Date.parse(`${day}T${hhmm}:00+08:00`);

test('pushes use the name grandma set, falling back to 長輩', () => {
  const core = {families: {g: {name: '林緣'}}, devices: {g: {name: '長輩'}}};
  assert.equal(hostName(core, 'g'), '林緣');
  assert.equal(hostName({}, 'g'), '長輩');
  assert.equal(alertPush('sos', 'g', 'a', '林緣').title, 'SOS 林緣緊急求助');
  assert.equal(alertPush('call', 'g', 'a', '林緣').title, '林緣找你');
  assert.equal(alertPush('call', 'g', 'a').title, '長輩找你');
  assert.equal(placeMessage({place: 'home', transition: 'enter', at: at('18:05')}, '工作地點', '林緣').title, '林緣到家了');
});

test('evening summary only includes what the family may already see', () => {
  const care = {
    reminderStatus: {days: {[day]: {a: {state: 'played'}, b: {state: 'silent'}, c: {state: 'text_fallback'}}}},
    places: {consent: on(1), events: {
      e1: {place: 'home', transition: 'exit', at: at('09:00')},
      e2: {place: 'home', transition: 'enter', at: at('11:00')},
      old: {place: 'home', transition: 'exit', at: at('09:00') - 86_400_000},
    }},
    appUsage: {consent: on(1), days: {[day]: {total: 130, apps: [{name: 'YouTube', minutes: 95}]}}},
    companion: {consent: {...on(1), items: {mood: true}}, mood: {[day]: {mood: 'good'}}},
  };
  const s = digest.dailySummary('林緣', care, day);
  assert.equal(s.title, '林緣今天的狀況');
  assert.equal(s.body, '提醒播出 2/3 次・出門 1 次、到家 1 次・手機用了 2 小時 10 分（最多：YouTube）・心情：很好');
  // Paused items disappear from the summary.
  care.places.consent.enabled = false;
  care.appUsage.consent.status = 'paused';
  care.companion.consent.items.mood = false;
  assert.equal(digest.dailySummary('林緣', care, day).body, '提醒播出 2/3 次');
  assert.equal(digest.dailySummary('林緣', {}, day), null);
});

test('noon check only with usage sharing; quiet when she used the phone', () => {
  const care = {appUsage: {consent: on(1), days: {[day]: {total: 2}}}};
  assert.match(digest.noonCheck('林緣', care, day).body, /只用了 2 分鐘/);
  assert.match(digest.noonCheck('林緣', {appUsage: {consent: on(1)}}, day).body, /還沒收到/);
  care.appUsage.days[day].total = 40;
  assert.equal(digest.noonCheck('林緣', care, day), null);
  assert.equal(digest.noonCheck('林緣', {appUsage: {consent: {...on(1), enabled: false}}}, day), null);
});

test('stale location notifies once per episode and defers to battery offline check', () => {
  const now = at('20:00');
  const care = {location: {consent: {...on(1), updatedAt: now - 10 * 3600_000},
    latest: {receivedAt: now - 7 * 3600_000}}};
  const first = digest.locationStale('林緣', care, now);
  assert.match(first.body, /超過 7 小時/);
  care.location.staleNotified = first.episode;
  assert.equal(digest.locationStale('林緣', care, now + 3600_000), null);
  care.location.latest.receivedAt = now - 3600_000;
  assert.equal(digest.locationStale('林緣', care, now), null, 'fresh again');
  const withBattery = {...care, location: {...care.location, latest: {receivedAt: now - 9 * 3600_000}},
    battery: {consent: on(2)}};
  assert.equal(digest.locationStale('林緣', withBattery, now), null);
});

test('holiday greeting and rotating greeter', () => {
  assert.equal(digest.holidayGreeting('林緣', '2026-10-18'), '林緣，重陽節快樂！祝你身體健康、天天開心');
  assert.equal(digest.holidayGreeting('林緣', '2026-10-19'), null);
  const a = digest.pickGreeter(['bob', 'amy'], '2026-10-18');
  const b = digest.pickGreeter(['bob', 'amy'], '2026-12-22');
  assert.ok(['amy', 'bob'].includes(a));
  assert.notEqual(a, digest.pickGreeter(['bob', 'amy'], '2026-10-19'));
  assert.ok(b);
  assert.equal(digest.pickGreeter([], '2026-10-18'), null);
});

test('photo reaction line: new heart or new comment only', () => {
  assert.equal(photoReactionLine(null, {heart: true, comment: ''}), '我在你的照片按了愛心');
  assert.equal(photoReactionLine({heart: true}, {heart: true, comment: ''}), null);
  assert.equal(photoReactionLine({heart: true}, {heart: false, comment: ''}), null);
  assert.equal(photoReactionLine({heart: true, comment: 'a'}, {heart: true, comment: '好漂亮！'}), '我在你的照片留言：好漂亮！');
  assert.equal(photoReactionLine({comment: '好漂亮！'}, {heart: true, comment: '好漂亮！'}), '我在你的照片按了愛心');
});
