// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import {Fault, role, member, memberName} from './state.js';

/** Phone numbers for grandma's "打電話給…" fallback. Each family member enters
 * their own; it only shows on grandma's phone after she confirms it there.
 */
const PHONE = /^[0-9+][0-9 \-]{5,19}$/;
const fail = (code, message) => { throw new Fault(code, message); };

export function setContactPhone(core, contacts, uid, hostId, input, now) {
  role(core, uid, 'client');
  member(core, hostId, uid);
  if (core.links?.[uid]?.hostId !== hostId) fail('permission-denied', '已解除配對');
  const phone = typeof input?.phone === 'string' ? input.phone.trim() : '';
  if (phone === '') { delete contacts[uid]; return null; }
  if (!PHONE.test(phone)) fail('invalid-argument', '電話格式錯誤');
  contacts[uid] = {name: memberName(core, hostId, uid), phone, confirmed: false, updatedAt: now};
  return contacts[uid];
}

export function confirmContactPhone(core, contacts, uid, hostId, input, now) {
  role(core, hostId, 'host');
  if (uid !== hostId) fail('permission-denied', '只有長輩本機可以確認');
  const target = input?.uid;
  if (typeof target !== 'string' || !contacts[target]) fail('not-found', '找不到這位家人的電話');
  if (!core.families?.[hostId]?.members?.[target]) { delete contacts[target]; fail('not-found', '這位家人已解除配對'); }
  contacts[target].confirmed = input.confirmed === true;
  contacts[target].confirmedAt = now;
  return contacts[target];
}
