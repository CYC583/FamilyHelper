// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.reminders

import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime

/** v2 adds id, daily/once, a family voice recording and who set it.
 * v1 rows (no id) keep the old "date:type:time" delivery key.
 */
data class ReminderItem(
    val type: String,
    val time: String,
    val text: String,
    val id: String = "",
    val repeat: String = "daily",
    val date: String? = null,
    val voiceId: String? = null,
    val author: String = "",
    val authorUid: String? = null,
    /** Weekly reminders: ISO days, Monday = 1 … Sunday = 7. */
    val days: List<Int>? = null,
    /** Skipped up to and including this Taipei date. */
    val pausedUntil: String? = null,
) {
    fun occursOn(day: LocalDate): Boolean {
        if (pausedUntil != null && day.toString() <= pausedUntil) return false
        return when (repeat) {
            "once" -> date == day.toString()
            "weekly" -> days?.contains(day.dayOfWeek.value) == true
            else -> true
        }
    }

    fun keyFor(day: LocalDate) = if (id.isNotEmpty()) "$day:$id" else "$day:$type:$time"
}
data class DueReminder(val key: String, val item: ReminderItem, val scheduledAtMs: Long)

/** Pure policy for the host's locally consented reminders.
 *
 * This does not schedule Android work, display a notification or claim that a
 * reminder was delivered. A caller must persist [DueReminder.key] only after
 * Android actually accepts the notification attempt.
 */
object ReminderSchedulePolicy {
    private val taipei = ZoneId.of("Asia/Taipei")
    private val allowedTypes = setOf("medicine", "water", "rest", "photo", "custom")
    private val validTime = Regex("^(?:[01][0-9]|2[0-3]):[0-5][0-9]$")
    private const val MAX_LATE_MS = 60 * 60_000L

    fun due(
        nowMs: Long,
        items: List<ReminderItem>,
        deliveredKeys: Set<String>,
        closedDays: Set<LocalDate> = emptySet(),
    ): List<DueReminder> {
        val now = Instant.ofEpochMilli(nowMs).atZone(taipei)
        val date = now.toLocalDate()
        // The one-hour late window can extend past Taipei midnight.
        return items.flatMap { item ->
            listOf(date.minusDays(1), date).mapNotNull { candidate ->
                if (item.type !in allowedTypes || !validTime.matches(item.time) ||
                    item.text.length > 80 || item.text.any { it.code < 32 || it == '<' || it == '>' }) {
                    return@mapNotNull null
                }
                val time = try { LocalTime.parse(item.time) } catch (_: Exception) { return@mapNotNull null }
                if (!item.occursOn(candidate)) return@mapNotNull null
                val key = item.keyFor(candidate)
                if (key in deliveredKeys) return@mapNotNull null
                var scheduled = ZonedDateTime.of(candidate, time, taipei)
                if ((item.type == "water" || item.type == "rest") &&
                    candidate.dayOfWeek != DayOfWeek.SATURDAY && candidate.dayOfWeek != DayOfWeek.SUNDAY &&
                    candidate !in closedDays && !time.isBefore(LocalTime.of(9, 0)) &&
                    time.isBefore(LocalTime.of(13, 30))) {
                    scheduled = ZonedDateTime.of(candidate, LocalTime.of(13, 30), taipei)
                }
                val dueAt = scheduled.toInstant().toEpochMilli()
                if (nowMs < dueAt || nowMs - dueAt > MAX_LATE_MS) return@mapNotNull null
                DueReminder(key, item, dueAt)
            }
        }.sortedWith(compareBy<DueReminder> { it.scheduledAtMs }.thenBy { it.key })
    }
}
