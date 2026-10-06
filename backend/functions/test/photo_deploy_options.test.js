// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as functions from '../src/index.js';

test('five photo entrypoints retain the deployed single-instance ceiling', () => {
  for (const name of [
    'setPhotoConsent', 'revokePhotoConsent', 'uploadCarePhoto',
    'getCarePhoto', 'listCarePhotos',
  ]) {
    assert.equal(functions[name].__endpoint.maxInstances, 1, name);
    assert.equal(functions[name].__endpoint.minInstances ?? 0, 0, name);
    assert.equal(functions[name].__endpoint.timeoutSeconds, 30, name);
  }
  assert.equal(functions.unpairDevice.__endpoint.maxInstances, 5);
  assert.equal(functions.cleanup.__endpoint.maxInstances, 1);
});

test('companion entrypoints and maintenance schedule stay single-instance', () => {
  for (const name of ['setCompanionConsent', 'recordReminderResponse', 'recordMood', 'reportSoundStatus',
    'sendCareMessage', 'getVoiceMessage', 'reactToPhoto', 'setReminderPlan', 'uploadReminderVoice',
    'getReminderVoice', 'setVoiceProfile', 'setPlaceAlerts', 'reportPlaceEvent', 'setContactPhone', 'confirmContactPhone', 'reportReminderStatus', 'setHandling',
    'setLocationSharing', 'reportLocation', 'requestHostUpdate', 'ringHostPhone', 'setAppUsageSharing',
    'reportAppUsage', 'setProfile']) {
    assert.equal(functions[name].__endpoint.maxInstances, 1, name);
    assert.equal(functions[name].__endpoint.minInstances ?? 0, 0, name);
  }
  assert.equal(functions.careMaintenance.__endpoint.maxInstances, 1);
});
