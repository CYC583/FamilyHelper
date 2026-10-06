// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.reminders

import org.junit.Assert.*
import org.junit.Test

class ReminderSettingsParserTest {
    @Test fun parsesValidatedFamilyPlanWithoutInventingMedicineDose() {
        val plan = ReminderSettingsParser.parse(mapOf(
            "version" to 3L,
            "timezone" to "Asia/Taipei",
            "items" to listOf(mapOf("type" to "medicine", "time" to "08:00", "text" to "早藥")),
        ))
        assertEquals(3, plan?.version)
        assertEquals("早藥", plan?.items?.single()?.text)
    }

    @Test fun rejectsWrongTimezoneExtraFieldsAndMalformedItemsAsAWhole() {
        val base = mapOf(
            "version" to 1L,
            "timezone" to "Asia/Taipei",
            "items" to listOf(mapOf("type" to "water", "time" to "14:00", "text" to "喝水")),
        )
        assertNull(ReminderSettingsParser.parse(base + ("timezone" to "UTC")))
        assertNull(ReminderSettingsParser.parse(base + ("items" to listOf(
            mapOf("type" to "water", "time" to "14:00", "text" to "喝水", "dose" to "2")))))
        assertNull(ReminderSettingsParser.parse(base + ("items" to listOf(
            mapOf("type" to "water", "time" to "14:00", "text" to "喝水"),
            mapOf("type" to "water", "time" to "14:00", "text" to "再喝水")))))
    }

    @Test fun missingSettingsMeansEmptyVersionZeroPlanNotAnError() {
        val empty = ReminderSettingsParser.parse(null)
        assertEquals(0, empty?.version)
        assertTrue(empty?.items?.isEmpty() == true)
    }
}
