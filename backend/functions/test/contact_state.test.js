// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as c from '../src/contact_state.js';
import * as m from '../src/state.js';

const core = {devices: {grandma: {role: 'host'}, bro: {role: 'client', name: '哥哥'}, eve: {role: 'client'}},
  families: {grandma: {members: {bro: {}}}}, links: {bro: {hostId: 'grandma'}}};

test('family enters own phone; only grandma confirms; changing it needs confirming again', () => {
  const contacts = {};
  assert.throws(() => c.setContactPhone(core, contacts, 'eve', 'grandma', {phone: '0912345678'}, 1));
  assert.throws(() => c.setContactPhone(core, contacts, 'bro', 'grandma', {phone: 'abc'}, 1));
  c.setContactPhone(core, contacts, 'bro', 'grandma', {phone: '0912-345-678'}, 1);
  assert.equal(contacts.bro.confirmed, false);
  assert.throws(() => c.confirmContactPhone(core, contacts, 'bro', 'grandma', {uid: 'bro', confirmed: true}, 2),
    {code: 'permission-denied'});
  c.confirmContactPhone(core, contacts, 'grandma', 'grandma', {uid: 'bro', confirmed: true}, 2);
  assert.equal(contacts.bro.confirmed, true);
  c.setContactPhone(core, contacts, 'bro', 'grandma', {phone: '0987654321'}, 3);
  assert.equal(contacts.bro.confirmed, false);
  c.setContactPhone(core, contacts, 'bro', 'grandma', {phone: ''}, 4);
  assert.equal(contacts.bro, undefined);
});

test('grandma can cancel a ring before anyone answers; family pages see cancelledAt', () => {
  const s = {};
  m.register(s, 'grandma', 'host', '長輩', 1);
  m.register(s, 'bro', 'client', '哥哥', 1);
  m.issueCode(s, 'grandma', 'h', 1); m.bind(s, 'bro', 'h', 1);
  s.families.grandma.alerts = {a1: {type: 'call', createdAt: 1}};
  m.ringFamily(s, 'grandma', 'c1', 'call', 1, 'a1');
  assert.equal(m.cancelRing(s, 'grandma', 'c1', 5), 'ended');
  assert.equal(s.families.grandma.alerts.a1.cancelledAt, 5);
  assert.throws(() => m.answerRing(s, 'bro', 'c1', 6), {code: 'failed-precondition'});
  assert.throws(() => m.cancelRing(s, 'bro', 'c1', 7), {code: 'permission-denied'});
});
