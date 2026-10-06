// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
/** Server-side notes for the family and greetings for grandma. Pure
 * functions: each only uses data the family is already allowed to see.
 */
export const LOCATION_STALE_MS = 6 * 60 * 60_000;
export const NOON_LOW_MINUTES = 5;

const MOOD = {good: '很好', ok: '還可以', tired: '有點累', bad: '不太好'};
const minutes = m => (m < 60 ? `${m} 分鐘` : `${Math.floor(m / 60)} 小時${m % 60 ? ` ${m % 60} 分` : ''}`);
const consentOn = (c, version) => c?.enabled === true && c.status === 'enabled' &&
  (version == null || c.disclosureVersion === version);

/** Holidays (Taiwan) with a greeting read aloud on grandma's phone. Lunar
 * dates are listed explicitly per year.
 */
export const HOLIDAYS = {
  '2026-10-18': '重陽節快樂！祝你身體健康、天天開心',
  '2026-12-22': '冬至快樂！記得吃湯圓，身體暖暖的',
  '2027-01-01': '新年快樂！新的一年平安健康',
  '2027-02-05': '除夕快樂！今天要一起吃年夜飯喔',
  '2027-02-06': '新年快樂！恭喜發財，身體健康',
  '2027-02-20': '元宵節快樂！記得吃湯圓',
  '2027-05-09': '母親節快樂！謝謝你一直照顧我們',
  '2027-06-09': '端午節快樂！記得吃粽子',
  '2027-09-15': '中秋節快樂！我們很想你',
  '2027-10-08': '重陽節快樂！祝你身體健康、天天開心',
};

export function holidayGreeting(name, day) {
  const line = HOLIDAYS[day];
  return line ? `${name}，${line}` : null;
}

/** One family member per holiday, rotating, so it is not always the same. */
export function pickGreeter(memberIds, day) {
  const ids = [...memberIds].sort();
  if (!ids.length) return null;
  const n = Number(day.replaceAll('-', '')) || 0;
  return ids[n % ids.length];
}

/** Evening summary for the family; null when nothing is shared. */
export function dailySummary(name, care, day) {
  const parts = [];
  const statuses = Object.values(care?.reminderStatus?.days?.[day] || {});
  if (statuses.length) {
    const played = statuses.filter(s => s?.state === 'played' || s?.state === 'text_fallback').length;
    parts.push(`提醒播出 ${played}/${statuses.length} 次`);
  }
  if (consentOn(care?.places?.consent, 1)) {
    const events = Object.values(care.places.events || {}).filter(e =>
      typeof e?.at === 'number' && new Date(e.at + 8 * 3600_000).toISOString().slice(0, 10) === day);
    const out = events.filter(e => e.transition === 'exit').length;
    const home = events.filter(e => e.transition === 'enter' && e.place === 'home').length;
    parts.push(out || home ? `出門 ${out} 次、到家 ${home} 次` : '今天沒有出門紀錄');
  }
  if (consentOn(care?.appUsage?.consent, 1)) {
    const total = care.appUsage.days?.[day]?.total;
    if (typeof total === 'number') {
      const top = care.appUsage.days[day].apps?.[0]?.name;
      parts.push(`手機用了 ${minutes(total)}${top ? `（最多：${top}）` : ''}`);
    }
  }
  if (care?.companion?.consent?.items?.mood === true && consentOn(care.companion.consent)) {
    const mood = MOOD[care.companion.mood?.[day]?.mood];
    if (mood) parts.push(`心情：${mood}`);
  }
  if (!parts.length) return null;
  return {title: `${name}今天的狀況`, body: parts.join('・')};
}

/** Noon check: grandma has barely used her phone. Only with usage sharing. */
export function noonCheck(name, care, day) {
  if (!consentOn(care?.appUsage?.consent, 1)) return null;
  const total = care.appUsage.days?.[day]?.total;
  if (typeof total === 'number' && total >= NOON_LOW_MINUTES) return null;
  return {
    title: `${name}今天還很少用手機`,
    body: typeof total === 'number'
      ? `到中午只用了 ${total} 分鐘，可以打個電話關心一下。`
      : `到中午還沒收到${name}手機的使用紀錄（可能沒網路或關機），可以打個電話關心一下。`,
  };
}

/** No position for a long time while location sharing is on. Skipped when
 * battery sharing is on: its own 3-hour offline check already covers this.
 * Returns the episode key to remember, so one episode notifies once.
 */
export function locationStale(name, care, now) {
  const loc = care?.location;
  if (!consentOn(loc?.consent, 1) || consentOn(care?.battery?.consent, 2)) return null;
  const since = Math.max(Number(loc.latest?.receivedAt) || 0, Number(loc.consent.updatedAt) || 0);
  if (!since || now - since < LOCATION_STALE_MS) return null;
  const episode = `stale-${since}`;
  if (loc.staleNotified === episode) return null;
  const hours = Math.floor((now - since) / 3600_000);
  return {
    episode,
    title: `${name}的手機很久沒有更新位置`,
    body: `已經超過 ${hours} 小時沒有收到位置，手機可能關機、沒電或沒網路，可以打個電話關心一下。`,
  };
}
