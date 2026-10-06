// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.care

import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime

/** Pure host-side companion rules. No Android, clock or network access here. */
object TaiwanMarket {
    val zone: ZoneId = ZoneId.of("Asia/Taipei")
    private val open = LocalTime.of(9, 0)
    private val close = LocalTime.of(13, 30)

    fun isOpen(nowMs: Long, closedDays: Set<LocalDate> = emptySet()): Boolean {
        val now = Instant.ofEpochMilli(nowMs).atZone(zone)
        if (now.dayOfWeek == DayOfWeek.SATURDAY || now.dayOfWeek == DayOfWeek.SUNDAY) return false
        if (now.toLocalDate() in closedDays) return false
        val time = now.toLocalTime()
        return !time.isBefore(open) && time.isBefore(close)
    }

    fun closeMs(nowMs: Long): Long = ZonedDateTime.of(
        Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate(), close, zone).toInstant().toEpochMilli()

    fun day(nowMs: Long): LocalDate = Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate()
}

enum class RestAction { NONE, REMIND_NOW, DEFERRED, SNOOZED }
data class RestDecision(val action: RestAction, val atMs: Long? = null)

/** Mirrors lib/app/common/care_reminder_rules.dart. Continuous screen time must
 * come from screen on/off events only; app names are never an input.
 */
object RestReminderPolicy {
    const val THRESHOLD_MS = 90 * 60_000L
    const val COOLDOWN_MS = 30 * 60_000L

    fun decide(
        nowMs: Long,
        continuousMs: Long,
        enabled: Boolean,
        snoozedUntilMs: Long?,
        lastRemindedAtMs: Long?,
        closedDays: Set<LocalDate> = emptySet(),
    ): RestDecision {
        if (!enabled || continuousMs < THRESHOLD_MS) return RestDecision(RestAction.NONE)
        if (snoozedUntilMs != null && nowMs < snoozedUntilMs) return RestDecision(RestAction.SNOOZED, snoozedUntilMs)
        if (lastRemindedAtMs != null && nowMs - lastRemindedAtMs < COOLDOWN_MS) return RestDecision(RestAction.NONE)
        if (TaiwanMarket.isOpen(nowMs, closedDays)) return RestDecision(RestAction.DEFERRED, TaiwanMarket.closeMs(nowMs))
        return RestDecision(RestAction.REMIND_NOW)
    }
}

/** Morning card: once per Taipei day, at most one hour late, never back-filled. */
object MorningPolicy {
    private val validTime = Regex("^(?:[01][0-9]|2[0-3]):[0-5][0-9]$")
    private const val LATE_MS = 60 * 60_000L

    fun dueKey(nowMs: Long, morningTime: String?, lastKey: String?): String? {
        if (morningTime == null || !validTime.matches(morningTime)) return null
        val date = TaiwanMarket.day(nowMs)
        val at = ZonedDateTime.of(date, LocalTime.parse(morningTime), TaiwanMarket.zone).toInstant().toEpochMilli()
        val key = "$date:$morningTime"
        if (key == lastKey || nowMs < at || nowMs - at > LATE_MS) return null
        return key
    }
}

data class SoundState(val ringer: String, val dnd: Boolean, val mediaZero: Boolean) {
    val quiet get() = ringer == "silent" || dnd
    /** Plain-language problems shown on the host; empty means nothing found. */
    fun problems(): List<String> = buildList {
        if (ringer == "silent") add("鈴聲是靜音，來電和通知不會響")
        if (ringer == "vibrate") add("鈴聲是震動，來電只會震動")
        if (dnd) add("勿擾模式開著，家人來電可能不會響")
        if (mediaZero) add("媒體音量是零，影片和朗讀聽不到")
    }
}

object SoundPolicy {
    // AudioManager.RINGER_MODE_* and NotificationManager.INTERRUPTION_FILTER_ALL values.
    fun classify(ringerMode: Int, interruptionFilter: Int, mediaVolume: Int): SoundState = SoundState(
        ringer = when (ringerMode) { 0 -> "silent"; 1 -> "vibrate"; else -> "normal" },
        dnd = interruptionFilter > 1,
        mediaZero = mediaVolume <= 0,
    )
}

data class MorningWeather(
    val city: String, val temperatureC: Double, val weatherCode: Int,
    val highC: Double, val lowC: Double, val rainChance: Int?,
)

/** Same wording as WeatherReport.spokenSummary in Dart. */
object MorningScript {
    fun condition(code: Int): String = when {
        code == 0 -> "晴朗"
        code <= 2 -> "晴時多雲"
        code == 3 -> "多雲"
        code == 45 || code == 48 -> "有霧"
        code in 51..67 -> "有雨"
        code in 71..77 -> "有雪"
        code in 80..82 -> "有陣雨"
        code in 85..86 -> "有陣雪"
        code in 95..99 -> "有雷雨"
        else -> "天氣狀況待確認"
    }

    fun weather(w: MorningWeather): String {
        val now = Math.round(w.temperatureC)
        val hi = Math.round(w.highC); val lo = Math.round(w.lowC)
        val tip = when {
            (w.rainChance ?: 0) >= 60 || w.weatherCode in 51..67 || w.weatherCode in 80..82 || w.weatherCode in 95..99 -> "今天可能會下雨，出門記得帶傘喔。"
            hi >= 32 -> "天氣比較熱，記得多喝水、別曬太久喔。"
            lo <= 15 -> "早晚比較涼，記得多穿一件外套喔。"
            else -> "是舒服的一天，出門走走也很好喔。"
        }
        return "今天${w.city}現在大約${now}度，${condition(w.weatherCode)}，最高${hi}度、最低${lo}度。$tip"
    }

    /** Never invents weather: without a fresh forecast only the quote is read.
     * When a family member's own "早安" clip was played first, skip the greeting.
     */
    fun compose(weather: MorningWeather?, quote: String?, weatherConfigured: Boolean, greeted: Boolean = false): String {
        val parts = mutableListOf(if (greeted) "" else "長輩早安～")
        when {
            weather != null -> parts += weather(weather)
            weatherConfigured -> parts += "今天的天氣還沒抓到，晚點再看看喔。"
        }
        quote?.trim()?.takeIf { it.isNotEmpty() }?.let { parts += "今天的一句話：$it" }
        return parts.joinToString("")
    }
}

/** One family voice per day for the morning card, in a stable order. */
object WeatherRotation {
    fun pick(day: java.time.LocalDate, members: List<String>): String? {
        if (members.isEmpty()) return null
        val sorted = members.sorted()
        return sorted[Math.floorMod(day.toEpochDay(), sorted.size.toLong()).toInt()]
    }
}
