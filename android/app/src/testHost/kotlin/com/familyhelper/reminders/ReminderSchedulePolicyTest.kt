// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.reminders

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.util.TimeZone

class ReminderSchedulePolicyTest {
    private fun at(value: String) = Instant.parse(value).toEpochMilli()

    @Test fun medicineIsNotDelayedByMarketHours() {
        val due = ReminderSchedulePolicy.due(
            at("2026-10-02T02:05:00Z"),
            listOf(ReminderItem("medicine", "10:00", "早藥")),
            emptySet(),
        )
        assertEquals(1, due.size)
        assertEquals("medicine", due.single().item.type)
    }

    @Test fun waterAndRestWaitUntilMarketClosesButPhotoDoesNot() {
        val items = listOf(
            ReminderItem("water", "10:00", "喝水"),
            ReminderItem("rest", "10:00", "休息"),
            ReminderItem("photo", "10:00", "拍張照"),
        )
        val morning = ReminderSchedulePolicy.due(at("2026-10-02T02:05:00Z"), items, emptySet())
        assertEquals(listOf("photo"), morning.map { it.item.type })
        val close = ReminderSchedulePolicy.due(at("2026-10-02T05:35:00Z"), items, emptySet())
        assertEquals(setOf("water", "rest"), close.map { it.item.type }.toSet())
    }

    @Test fun saturdayWaterIsNotDelayedAndDeliveryKeyIsOnePerTaipeiDay() {
        val item = ReminderItem("water", "10:00", "喝水")
        val now = at("2026-10-03T02:05:00Z")
        val first = ReminderSchedulePolicy.due(now, listOf(item), emptySet()).single()
        assertTrue(first.key.startsWith("2026-10-03:"))
        assertTrue(ReminderSchedulePolicy.due(now, listOf(item), setOf(first.key)).isEmpty())
    }

    @Test fun excessivelyLateJobDoesNotAnnounceAnOldMedicationReminder() {
        val due = ReminderSchedulePolicy.due(
            at("2026-10-02T07:00:00Z"),
            listOf(ReminderItem("medicine", "10:00", "早藥")),
            emptySet(),
        )
        assertTrue(due.isEmpty())
    }

    @Test fun lateNightReminderStillUsesPreviousTaipeiDateAfterMidnight() {
        val due = ReminderSchedulePolicy.due(
            at("2026-10-02T16:10:00Z"), // Taipei 10/3 00:10.
            listOf(ReminderItem("medicine", "23:50", "睡前藥")),
            emptySet(),
        )
        assertEquals(1, due.size)
        assertTrue(due.single().key.startsWith("2026-10-02:"))
    }

    @Test fun malformedCachedSettingsAreNotEligibleForSpeech() {
        val due = ReminderSchedulePolicy.due(
            at("2026-10-02T02:05:00Z"),
            listOf(
                ReminderItem("medicine", "10:00:00", "extra seconds"),
                ReminderItem("medicine", "10:00", "a".repeat(81)),
                ReminderItem("urgent", "10:00", "fake type"),
            ),
            emptySet(),
        )
        assertTrue(due.isEmpty())
    }

    @Test fun taipeiCalendarIsIndependentOfPhoneTimeZoneAndClosedMarketDayDoesNotDelayWater() {
        val old = TimeZone.getDefault()
        try {
            TimeZone.setDefault(TimeZone.getTimeZone("America/Los_Angeles"))
            val due = ReminderSchedulePolicy.due(
                at("2026-10-02T02:05:00Z"),
                listOf(ReminderItem("water", "10:00", "喝水")),
                emptySet(),
                closedDays = setOf(LocalDate.of(2026, 10, 2)),
            )
            assertEquals(1, due.size)
            assertTrue(due.single().key.startsWith("2026-10-02:"))
        } finally {
            TimeZone.setDefault(old)
        }
    }
}
