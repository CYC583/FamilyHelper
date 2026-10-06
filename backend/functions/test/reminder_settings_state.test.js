// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';
import {setReminderSettings} from '../src/reminder_settings_state.js';

function family() {
  return {core: {devices: {grandma: {role: 'host'}, alice: {role: 'client'},
    bob: {role: 'client'}, outsider: {role: 'client'}},
    families: {grandma: {members: {alice: true, bob: true}}},
    links: {alice: {hostId: 'grandma'}, bob: {hostId: 'grandma'}}}};
}
const plan = {expectedVersion: 0, items: [
  {type: 'water', time: '14:00', text: '喝點水，休息一下'},
  {type: 'medicine', time: '08:00', text: ''},
]};

test('paired family can save a bounded daily plan without a default dose', () => {
  const root = family();
  const saved = setReminderSettings(root, 'alice', 'grandma', plan, 1234);
  assert.equal(saved.version, 1);
  assert.equal(saved.timezone, 'Asia/Taipei');
  assert.deepEqual(saved.items.map(item => item.type), ['medicine', 'water']);
  assert.equal(saved.items[0].text, '');
  assert.equal(root.care.grandma.settings.reminders.updatedBy, 'alice');
});

test('unpaired, stale, duplicate, overlong and malformed reminders reject without writes', () => {
  for (const [uid, input] of [
    ['outsider', plan],
    ['grandma', plan],
    ['alice', {...plan, expectedVersion: 1}],
    ['alice', {...plan, items: Array(13).fill(plan.items[0])}],
    ['alice', {...plan, items: [plan.items[0], plan.items[0]]}],
    ['alice', {...plan, items: [{type: 'medicine', time: '25:00'}]}],
    ['alice', {...plan, items: [{type: 'medicine', time: '08:00', dose: '2 pills'}]}],
    ['alice', {...plan, items: [{type: 'photo', time: '09:00', text: '<script>'}]}],
  ]) {
    const root = family();
    assert.throws(() => setReminderSettings(root, uid, 'grandma', input, 1234));
    assert.equal(root.care, undefined);
  }
});

test('second family member must use latest version to avoid overwriting another plan', () => {
  const root = family();
  setReminderSettings(root, 'alice', 'grandma', plan, 1234);
  assert.throws(() => setReminderSettings(root, 'bob', 'grandma', plan, 1235),
    {code: 'aborted'});
  const empty = setReminderSettings(root, 'bob', 'grandma',
    {expectedVersion: 1, items: []}, 1236);
  assert.deepEqual(empty.items, []);
  assert.equal(empty.version, 2);
});
