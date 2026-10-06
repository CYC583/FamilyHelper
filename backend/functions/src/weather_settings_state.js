// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import {Fault, role, member} from './state.js';

const invalid = () => { throw new Fault('invalid-argument', '請確認城市與早安播報時間'); };

/** Pure transition; call only inside a root transaction with current /core. */
export function setWeatherSettings(root, uid, hostId, input, now) {
  const core = root?.core || {};
  role(core, uid, 'client');
  role(core, hostId, 'host');
  member(core, hostId, uid);
  if (core.links?.[uid]?.hostId !== hostId) {
    throw new Fault('permission-denied', '尚未綁定或已解除綁定');
  }
  if (!Number.isSafeInteger(input?.expectedVersion) || input.expectedVersion < 0) invalid();
  const city = input.city;
  const name = typeof city?.name === 'string' ? city.name.trim() : '';
  if (!name || name.length > 40 || /[\x00-\x1f<>]/.test(name) ||
      !Number.isFinite(city?.latitude) || !Number.isFinite(city?.longitude) ||
      Math.abs(city.latitude) > 90 || Math.abs(city.longitude) > 180 ||
      typeof input.morningTime !== 'string' ||
      !/^(?:[01][0-9]|2[0-3]):[0-5][0-9]$/.test(input.morningTime) ||
      !Number.isSafeInteger(now) || now < 0) invalid();
  const currentVersion = root.care?.[hostId]?.settings?.weather?.version || 0;
  if (currentVersion !== input.expectedVersion) {
    throw new Fault('aborted', '其他家人已更新設定，請重新整理再儲存');
  }
  const next = {
    version: currentVersion + 1,
    city: {name, latitude: city.latitude, longitude: city.longitude},
    morningTime: input.morningTime,
    timezone: 'Asia/Taipei',
    updatedAt: now,
    updatedBy: uid,
  };
  root.care ??= {};
  root.care[hostId] ??= {};
  root.care[hostId].settings ??= {};
  root.care[hostId].settings.weather = next;
  return next;
}
