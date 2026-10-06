// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import {Fault} from './state.js';

/** Each phone sets its own display name and (optionally) a small photo. */
export const MAX_AVATAR_BASE64 = 60_000;
const NAME = /^[^\x00-\x1f<>]{1,12}$/;
const fail = (code, message) => { throw new Fault(code, message); };

export function cleanName(value) {
  const name = typeof value === 'string' ? value.trim() : '';
  if (!NAME.test(name)) fail('invalid-argument', '名字請在 12 個字內，不要輸入 < >');
  return name;
}

/** Square JPEG, base64, small enough to keep in the database. */
export function cleanAvatar(value) {
  if (typeof value !== 'string' || value.length < 100 || value.length > MAX_AVATAR_BASE64 ||
      !/^[A-Za-z0-9+/]+=*$/.test(value)) fail('invalid-argument', '頭貼太大或格式錯誤');
  const bytes = Buffer.from(value, 'base64');
  if (bytes[0] !== 0xff || bytes[1] !== 0xd8 || bytes[bytes.length - 2] !== 0xff || bytes[bytes.length - 1] !== 0xd9) {
    fail('invalid-argument', '頭貼必須是照片');
  }
  return value;
}

/** Name change inside the /core transaction. Returns the family to update. */
export function setProfileName(s, uid, name, now) {
  const device = s.devices?.[uid];
  if (!device) fail('failed-precondition', '未註冊裝置');
  device.name = name;
  device.updatedAt = now;
  device.profileSetAt = now;
  if (device.role === 'host') {
    if (s.families?.[uid]) s.families[uid].name = name;
    return uid;
  }
  const hostId = s.links?.[uid]?.hostId;
  if (hostId && s.families?.[hostId]?.members?.[uid]) s.families[hostId].members[uid].name = name;
  return hostId || null;
}
