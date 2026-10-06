// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.reminders

import com.familyhelper.care.CareNotifier
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class ReminderPlanV2Test {
    private fun at(value: String) = Instant.parse(value).toEpochMilli()

    @Test fun parsesV2RowsWithVoiceOnceAndAuthor() {
        val plan = ReminderSettingsParser.parse(mapOf("version" to 3L, "timezone" to "Asia/Taipei", "items" to listOf(
            mapOf("id" to "r-1", "type" to "custom", "repeat" to "once", "date" to "2026-10-05", "time" to "15:30",
                "text" to "", "voiceId" to "v-1", "author" to "小明", "createdBy" to "x", "updatedAt" to 1L),
            mapOf("id" to "r-2", "type" to "medicine", "repeat" to "daily", "time" to "08:00", "text" to "吃藥"),
        )))!!
        assertEquals(2, plan.items.size)
        assertEquals("v-1", plan.items[0].voiceId)
        assertEquals("小明", plan.items[0].author)
        assertNull("unknown keys still rejected", ReminderSettingsParser.parse(mapOf("version" to 1L,
            "timezone" to "Asia/Taipei", "items" to listOf(mapOf("type" to "water", "time" to "08:00", "dose" to "2")))))
    }

    @Test fun onceRemindersOnlyFireOnTheirDateAndUseIdKeys() {
        val once = ReminderItem("custom", "15:30", "回診", id = "r-1", repeat = "once", date = "2026-10-05")
        assertTrue(ReminderSchedulePolicy.due(at("2026-10-04T07:31:00Z"), listOf(once), emptySet()).isEmpty())
        val due = ReminderSchedulePolicy.due(at("2026-10-05T07:31:00Z"), listOf(once), emptySet()).single()
        assertEquals("2026-10-05:r-1", due.key)
        assertTrue(ReminderSchedulePolicy.due(at("2026-10-05T07:40:00Z"), listOf(once), setOf(due.key)).isEmpty())
        assertTrue(ReminderSchedulePolicy.due(at("2026-10-06T07:31:00Z"), listOf(once), emptySet()).isEmpty())
    }

    @Test fun spokenLineNamesTheFamilyMember() {
        assertEquals("長輩，小明提醒你：吃血壓藥", CareNotifier.spokenLine("medicine", "吃血壓藥", "小明"))
        assertEquals("長輩，家人有話要跟你說。", CareNotifier.spokenLine("custom", "", ""))
    }
}

class ReminderWeeklyPauseTest {
    private fun at(value: String) = java.time.Instant.parse(value).toEpochMilli()

    @org.junit.Test fun weeklyOnlyOnChosenDaysAndPauseSkips() {
        // 2026-10-06 is a Tuesday.
        val weekly = ReminderItem("custom", "09:00", "帶健保卡", id = "w", repeat = "weekly", days = listOf(2, 4))
        org.junit.Assert.assertEquals(1, ReminderSchedulePolicy.due(at("2026-10-06T01:01:00Z"), listOf(weekly), emptySet()).size)
        org.junit.Assert.assertTrue(ReminderSchedulePolicy.due(at("2026-10-07T01:01:00Z"), listOf(weekly), emptySet()).isEmpty())
        val paused = weekly.copy(pausedUntil = "2026-10-06")
        org.junit.Assert.assertTrue(ReminderSchedulePolicy.due(at("2026-10-06T01:01:00Z"), listOf(paused), emptySet()).isEmpty())
        org.junit.Assert.assertEquals(1, ReminderSchedulePolicy.due(at("2026-10-08T01:01:00Z"), listOf(paused), emptySet()).size)
    }

    @org.junit.Test fun parsesWeeklyDaysAndPause() {
        val plan = ReminderSettingsParser.parse(mapOf("version" to 1L, "timezone" to "Asia/Taipei", "items" to listOf(
            mapOf("id" to "w", "type" to "custom", "repeat" to "weekly", "days" to listOf(2L, 4L), "time" to "09:00",
                "text" to "x", "pausedUntil" to "2026-10-10", "editedBy" to "哥哥"))))!!
        org.junit.Assert.assertEquals(listOf(2, 4), plan.items[0].days)
        org.junit.Assert.assertEquals("2026-10-10", plan.items[0].pausedUntil)
    }
}
