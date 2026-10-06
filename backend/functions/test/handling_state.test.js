// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';
import {setHandling} from '../src/handling_state.js';

const core = {devices: {grandma: {role: 'host'}, bro: {role: 'client', name: '哥哥'}, sis: {role: 'client', name: '妹妹'},
  eve: {role: 'client'}}, families: {grandma: {members: {bro: {}, sis: {}}}},
links: {bro: {hostId: 'grandma'}, sis: {hostId: 'grandma'}}};

test('one member claims; others see it and cannot steal; release then resolve with a note', () => {
  const h = {};
  assert.equal(setHandling(core, h, 'bro', 'grandma', {eventKey: 'battery-e1', action: 'claim'}, 1).name, '哥哥');
  assert.throws(() => setHandling(core, h, 'sis', 'grandma', {eventKey: 'battery-e1', action: 'claim'}, 2),
    /哥哥 已經在處理/);
  assert.throws(() => setHandling(core, h, 'sis', 'grandma', {eventKey: 'battery-e1', action: 'release'}, 2));
  setHandling(core, h, 'bro', 'grandma', {eventKey: 'battery-e1', action: 'release'}, 3);
  assert.equal(h['battery-e1'].status, 'open');
  setHandling(core, h, 'sis', 'grandma', {eventKey: 'battery-e1', action: 'resolve', note: '已打電話提醒充電'}, 4);
  assert.deepEqual(h['battery-e1'], {status: 'resolved', by: 'sis', name: '妹妹', at: 4, note: '已打電話提醒充電'});
});

test('outsiders, grandma and malformed keys are rejected', () => {
  for (const [uid, key] of [['eve', 'alert-a'], ['grandma', 'alert-a'], ['bro', 'x/y'], ['bro', 'photo-1']]) {
    assert.throws(() => setHandling(core, {}, uid, 'grandma', {eventKey: key, action: 'claim'}, 1));
  }
});
