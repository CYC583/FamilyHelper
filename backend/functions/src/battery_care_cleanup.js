// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
/** Pure 30-day retention for the battery scope. No Storage dependency. */
const RETENTION_MS = 30 * 24 * 60 * 60_000;
const validTime = value => Number.isSafeInteger(value) && value >= 0;
const expired = (value, now) => !validTime(value) || value <= now - RETENTION_MS;

export function needsBatteryCleanup(battery, now) {
  if (!validTime(now)) throw new TypeError('Invalid cleanup time');
  const events = battery?.events || {};
  if (Object.values(events).some(event => expired(event?.createdAt, now))) return true;
  return Object.entries(battery?.pushOps || {}).some(([eventId, members]) =>
    !events[eventId] || Object.values(members || {}).some(op => expired(op?.attemptedAt, now)));
}

export function pruneBatteryCare(battery, now) {
  if (!validTime(now)) throw new TypeError('Invalid cleanup time');
  const next = structuredClone(battery || {});
  let removedEvents = 0;
  let removedAttempts = 0;
  next.events ??= {};
  next.pushOps ??= {};
  for (const [eventId, event] of Object.entries(next.events)) {
    if (!expired(event?.createdAt, now)) continue;
    delete next.events[eventId];
    removedEvents++;
  }
  for (const [eventId, members] of Object.entries(next.pushOps)) {
    if (!next.events[eventId]) {
      removedAttempts += Object.keys(members || {}).length;
      delete next.pushOps[eventId];
      continue;
    }
    for (const [uid, op] of Object.entries(members || {})) {
      if (!expired(op?.attemptedAt, now)) continue;
      delete next.pushOps[eventId][uid];
      removedAttempts++;
    }
    if (!Object.keys(next.pushOps[eventId]).length) delete next.pushOps[eventId];
  }
  return {battery: next, removedEvents, removedAttempts};
}

/** Called before optional photo cleanup, so missing Storage configuration cannot
 * prevent private battery retention from running. The caller supplies exact
 * currently registered host IDs instead of reading the entire /care tree.
 */
export async function runBatteryCleanup({hostIds, readBattery, transactBattery, now}) {
  const summary = {hostsChecked: 0, hostsChanged: 0, removedEvents: 0, removedAttempts: 0};
  for (const hostId of hostIds) {
    const current = await readBattery(hostId);
    summary.hostsChecked++;
    if (!needsBatteryCleanup(current, now)) continue;
    const next = await transactBattery(hostId, battery => pruneBatteryCare(battery, now).battery);
    // The committed state is authoritative; count removals against the snapshot
    // only for operational visibility, not for access-control decisions.
    const beforeEvents = Object.keys(current?.events || {}).length;
    const afterEvents = Object.keys(next?.events || {}).length;
    const countAttempts = value => Object.values(value?.pushOps || {}).reduce(
      (count, recipients) => count + Object.keys(recipients || {}).length, 0);
    summary.hostsChanged++;
    summary.removedEvents += Math.max(0, beforeEvents - afterEvents);
    summary.removedAttempts += Math.max(0, countAttempts(current) - countAttempts(next));
  }
  return summary;
}
