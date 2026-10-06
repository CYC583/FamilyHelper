// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as place from '../src/place_alert_state.js';

const NOW = Date.UTC(2026, 9, 3, 0, 12); // 08:12 Taipei
const core = {devices: {grandma: {role: 'host'}, alice: {role: 'client'}}, families: {grandma: {members: {alice: {}}}}};

test('only grandma enables; events need consent; coordinates are never accepted', () => {
  const p = {};
  assert.throws(() => place.setPlaceAlerts(core, p, 'alice', 'grandma', {enabled: true, disclosureVersion: 1}, NOW),
    {code: 'permission-denied'});
  assert.throws(() => place.reportPlaceEvent(core, p, 'grandma', 'grandma',
    {place: 'home', transition: 'exit', at: NOW, consentVersion: 1}, NOW, 'e1'), {code: 'failed-precondition'});
  const c = place.setPlaceAlerts(core, p, 'grandma', 'grandma', {enabled: true, disclosureVersion: 1, homeSet: true}, NOW);
  const e = place.reportPlaceEvent(core, p, 'grandma', 'grandma',
    {place: 'home', transition: 'exit', at: NOW, consentVersion: c.version}, NOW, 'e1');
  assert.deepEqual(Object.keys(e).sort(), ['at', 'place', 'receivedAt', 'transition']);
  assert.deepEqual(place.placeMessage(e), {title: '長輩離開家了', body: '08:12 離開家。'});
  assert.throws(() => place.reportPlaceEvent(core, p, 'grandma', 'grandma',
    {place: 'home', transition: 'exit', at: NOW, consentVersion: c.version, lat: 25}, NOW, 'e2'));
});

test('duplicate transitions within 10 minutes are ignored; pause stops; revoke deletes history', () => {
  const p = {};
  const c = place.setPlaceAlerts(core, p, 'grandma', 'grandma', {enabled: true, disclosureVersion: 1}, NOW);
  const report = (at, transition = 'enter', id = `e${at}`) => place.reportPlaceEvent(core, p, 'grandma', 'grandma',
    {place: 'work', transition, at, consentVersion: c.version}, at, id);
  assert.ok(report(NOW));
  assert.equal(report(NOW + 60_000), null);
  assert.ok(report(NOW + 11 * 60_000));
  place.setPlaceAlerts(core, p, 'grandma', 'grandma', {enabled: false}, NOW + 1);
  assert.equal(p.consent.status, 'paused');
  assert.ok(p.events);
  assert.throws(() => report(NOW + 30 * 60_000, 'exit'), {code: 'failed-precondition'});
  place.setPlaceAlerts(core, p, 'grandma', 'grandma', {enabled: false, revoke: true}, NOW + 2);
  assert.equal(p.events, undefined);
});

test('the second place can be renamed and appears in the alert text', () => {
  const p = {};
  const c = place.setPlaceAlerts(core, p, 'grandma', 'grandma', {enabled: true, disclosureVersion: 1, workName: '活動中心'}, NOW);
  assert.equal(c.workName, '活動中心');
  assert.equal(place.placeMessage({place: 'work', transition: 'enter', at: NOW}, c.workName).title, '長輩到活動中心了');
  assert.equal(place.setPlaceAlerts(core, {}, 'grandma', 'grandma', {enabled: true, disclosureVersion: 1, workName: '<x>'}, NOW).workName, '工作地點');
});
