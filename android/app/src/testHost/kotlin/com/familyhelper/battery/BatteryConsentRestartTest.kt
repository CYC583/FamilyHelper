// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.battery

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class BatteryConsentRestartTest {
    @Test fun lowBatteryPauseResumeBeginsNewEpisodeButKeepsSequence() {
        val old = BatteryState(episodeId = "old-episode", active = true,
            sampleSeq = 4, bootEpoch = "boot-1", firstLowElapsedMs = 1000,
            firstLowSeq = 1, lastElapsedMs = 2000, reminderLevel = 2)
        val fresh = BatteryConsentRestart.forNewGeneration(old)
        assertEquals(4L, fresh.sampleSeq)
        assertFalse(fresh.active)
        assertNull(fresh.episodeId)
        assertNull(fresh.firstLowSeq)
        val next = BatteryEngine.evaluate(fresh,
            BatteryReading(14, false, 5000, 5000, "boot-1"), "new-episode")
        assertEquals(5L, next.sample?.sampleSeq)
        assertEquals("new-episode", next.sample?.episodeId)
        assertEquals(5L, next.sample?.lowEvidence?.firstSampleSeq)
    }
}
