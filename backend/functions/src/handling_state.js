// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import {Fault, role, member, memberName} from './state.js';

/** Who in the family is taking care of an event. "Seen" (acknowledge) stays
 * separate; this is "I'll handle it" / "need help" / "done: <note>".
 */
const KEY = /^(alert|battery|sound)-[A-Za-z0-9_-]{1,80}$/;
const fail = (code, message) => { throw new Fault(code, message); };

export function setHandling(core, handling, uid, hostId, input, now) {
  role(core, uid, 'client');
  member(core, hostId, uid);
  if (core.links?.[uid]?.hostId !== hostId) fail('permission-denied', '已解除配對');
  const key = input?.eventKey;
  if (typeof key !== 'string' || !KEY.test(key)) fail('invalid-argument', '事件識別碼錯誤');
  const name = memberName(core, hostId, uid);
  const current = handling[key];
  const action = input.action;
  if (action === 'claim') {
    if (current?.status === 'claimed' && current.by !== uid) fail('failed-precondition', `${current.name} 已經在處理`);
    handling[key] = {status: 'claimed', by: uid, name, at: now};
  } else if (action === 'release') {
    if (current?.status !== 'claimed' || current.by !== uid) fail('failed-precondition', '只有接手的人可以交回');
    handling[key] = {status: 'open', by: uid, name, at: now, note: '需要其他人幫忙'};
  } else if (action === 'resolve') {
    const note = typeof input.note === 'string' ? input.note.trim() : '';
    if (note.length > 40 || /[\x00-\x1f<>]/.test(note)) fail('invalid-argument', '處理結果請在 40 字內');
    handling[key] = {status: 'resolved', by: uid, name, at: now, note: note || '已處理'};
  } else {
    fail('invalid-argument', '未知的操作');
  }
  const keys = Object.keys(handling).sort((a, b) => (handling[a].at || 0) - (handling[b].at || 0));
  while (keys.length > 200) delete handling[keys.shift()];
  return handling[key];
}
