// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
/** Admin RTDB transactions may initially see null even when server data exists.
 * Returning undefined on that provisional null would abort without a retry.
 * Propose an empty state on a failed null transition so Firebase can resolve the
 * server hash and retry with current data. If the server really is empty, surface
 * the error; no privileged operation is allowed by this fallback.
 */
export async function transact(ref, update) {
  let error;
  const result = await ref.transaction(current => {
    error = undefined;
    const next = current || {};
    try { update(next); return next; }
    catch (e) { error = e; return current === null ? {} : undefined; }
  }, undefined, false);
  if (error) throw error;
  if (!result.committed) throw new Error('Transaction aborted');
  return result.snapshot.val();
}
