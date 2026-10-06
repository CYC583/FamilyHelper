// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.care

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.LocalDate

class CarePoliciesTest {
    private fun at(value: String) = Instant.parse(value).toEpochMilli()
    private val ninetyMin = 90 * 60_000L

    @Test fun restNeedsNinetyMinutesOfContinuousScreenAndRespectsDisable() {
        val now = at("2026-10-03T07:00:00Z") // Saturday 15:00 Taipei
        assertEquals(RestAction.NONE, RestReminderPolicy.decide(now, ninetyMin - 1, true, null, null).action)
        assertEquals(RestAction.REMIND_NOW, RestReminderPolicy.decide(now, ninetyMin, true, null, null).action)
        assertEquals(RestAction.NONE, RestReminderPolicy.decide(now, ninetyMin * 2, false, null, null).action)
    }

    @Test fun restIsDeferredDuringWeekdayMarketHoursButNotOnClosedDays() {
        val tradingMorning = at("2026-10-02T02:00:00Z") // Friday 10:00 Taipei
        val deferred = RestReminderPolicy.decide(tradingMorning, ninetyMin, true, null, null)
        assertEquals(RestAction.DEFERRED, deferred.action)
        assertEquals(at("2026-10-02T05:30:00Z"), deferred.atMs)
        val holiday = RestReminderPolicy.decide(tradingMorning, ninetyMin, true, null, null,
            setOf(LocalDate.of(2026, 10, 2)))
        assertEquals(RestAction.REMIND_NOW, holiday.action)
    }

    @Test fun restSnoozeAndCooldownPreventRepeats() {
        val now = at("2026-10-03T07:00:00Z")
        assertEquals(RestAction.SNOOZED,
            RestReminderPolicy.decide(now, ninetyMin, true, now + 1, null).action)
        assertEquals(RestAction.NONE,
            RestReminderPolicy.decide(now, ninetyMin, true, null, now - 10 * 60_000L).action)
        assertEquals(RestAction.REMIND_NOW,
            RestReminderPolicy.decide(now, ninetyMin, true, now - 1, now - 31 * 60_000L).action)
    }

    @Test fun morningCardIsOncePerTaipeiDayWithinOneHourOnly() {
        val key = MorningPolicy.dueKey(at("2026-10-02T00:10:00Z"), "08:00", null)
        assertEquals("2026-10-02:08:00", key)
        assertNull(MorningPolicy.dueKey(at("2026-10-02T00:20:00Z"), "08:00", key))
        assertNull("too early", MorningPolicy.dueKey(at("2026-10-01T23:59:00Z"), "08:00", null))
        assertNull("over an hour late is skipped, not replayed",
            MorningPolicy.dueKey(at("2026-10-02T01:01:00Z"), "08:00", null))
        assertNull(MorningPolicy.dueKey(at("2026-10-02T00:10:00Z"), "8:00", null))
        assertNull(MorningPolicy.dueKey(at("2026-10-02T00:10:00Z"), null, null))
    }

    @Test fun soundClassificationExplainsEachProblemSeparately() {
        val silent = SoundPolicy.classify(0, 1, 5)
        assertTrue(silent.quiet)
        assertEquals(listOf("鈴聲是靜音，來電和通知不會響"), silent.problems())
        val dnd = SoundPolicy.classify(2, 3, 0)
        assertTrue(dnd.dnd && dnd.mediaZero && dnd.quiet)
        assertEquals(2, dnd.problems().size)
        val fine = SoundPolicy.classify(2, 1, 7)
        assertFalse(fine.quiet)
        assertTrue(fine.problems().isEmpty())
        assertFalse("vibrate is reported but not treated as silent", SoundPolicy.classify(1, 1, 7).quiet)
    }

    @Test fun morningScriptNeverInventsWeather() {
        val weather = MorningWeather("台北市", 27.6, 2, 31.2, 24.4, 40)
        val full = MorningScript.compose(weather, "慢慢來，比較快", true)
        assertTrue(full.contains("現在大約28度，晴時多雲"))
        assertFalse("no disclaimers read aloud", full.contains("請以實際天氣為準") || full.contains("Open-Meteo"))
        assertTrue(full.contains("今天的一句話：慢慢來，比較快"))
        val failed = MorningScript.compose(null, "慢慢來，比較快", true)
        assertTrue(failed.contains("今天的天氣還沒抓到"))
        assertFalse(failed.contains("度"))
        assertEquals("長輩早安～今天的一句話：好", MorningScript.compose(null, "好", false))
    }
}

class WeatherRotationTest {
    @Test fun rotatesOneMemberPerDayInStableOrder() {
        val day = java.time.LocalDate.of(2026, 10, 3)
        val members = listOf("bob", "alice")
        val picks = (0L..3L).map { WeatherRotation.pick(day.plusDays(it), members) }
        assertEquals(setOf("alice", "bob"), picks.toSet())
        assertNotEquals(picks[0], picks[1])
        assertEquals(picks[0], picks[2])
        assertNull(WeatherRotation.pick(day, emptyList()))
        val three = (0L..2L).map { WeatherRotation.pick(day.plusDays(it), listOf("a", "b", "c")) }.toSet()
        assertEquals(3, three.size)
    }

    @Test fun greetedScriptSkipsDuplicateHello() {
        val s = MorningScript.compose(null, "好", false, greeted = true)
        assertFalse(s.contains("早安"))
        assertTrue(s.contains("今天的一句話：好"))
    }
}
