// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.battery

import org.junit.Assert.*
import org.junit.Test

class BatteryEngineTest {
    private val base = 1_780_390_800_000L

    private fun reading(percent: Int, elapsed: Long, charging: Boolean = false,
                        boot: String = "boot-a", wall: Long = base + elapsed) =
        BatteryReading(percent, charging, wall, elapsed, boot)

    @Test fun firstLowRemindsOnceAndThirtyMinuteEvidenceNeedsTwoSamples() {
        val first = BatteryEngine.evaluate(BatteryState(), reading(30, 1_000), "ep-1")
        assertEquals("low", first.reminder)
        assertEquals(1L, first.sample?.sampleSeq)
        assertEquals(1L, first.sample?.lowEvidence?.firstSampleSeq)
        assertEquals(1L, first.sample?.lowEvidence?.currentSampleSeq)
        val early = BatteryEngine.evaluate(first.state, reading(29, 1_000 + 29 * 60_000L), "ignored")
        assertNull(early.reminder)
        assertEquals("ep-1", early.sample?.episodeId)
        val mature = BatteryEngine.evaluate(early.state, reading(29, 1_000 + 30 * 60_000L), "ignored")
        assertEquals(3L, mature.sample?.sampleSeq)
        assertEquals(30 * 60_000L, mature.sample!!.lowEvidence!!.currentMonotonicMs -
            mature.sample!!.lowEvidence!!.firstMonotonicMs)
    }

    @Test fun criticalRemindsOnceAndChargingResolvesThenNewLowGetsNewEpisode() {
        val first = BatteryEngine.evaluate(BatteryState(), reading(30, 1_000), "ep-1")
        val critical = BatteryEngine.evaluate(first.state, reading(15, 2_000), "ignored")
        assertEquals("critical", critical.reminder)
        assertEquals("critical", critical.sample?.severity)
        val repeated = BatteryEngine.evaluate(critical.state, reading(14, 3_000), "ignored")
        assertNull(repeated.reminder)
        val charging = BatteryEngine.evaluate(repeated.state, reading(14, 4_000, charging = true), "ignored")
        assertEquals("resolved", charging.reminder)
        assertEquals("resolved", charging.sample?.phase)
        val next = BatteryEngine.evaluate(charging.state, reading(29, 5_000), "ep-2")
        assertEquals("ep-2", next.sample?.episodeId)
        assertEquals("low", next.reminder)
        assertEquals(5L, next.sample?.sampleSeq)
    }

    @Test fun rebootResetsMonotonicEvidenceButKeepsEpisodeAndGlobalSequence() {
        val first = BatteryEngine.evaluate(BatteryState(), reading(30, 100_000), "ep-1")
        val reboot = BatteryEngine.evaluate(first.state, reading(30, 500, boot = "boot-b"), "ignored")
        assertEquals("ep-1", reboot.sample?.episodeId)
        assertEquals(2L, reboot.sample?.sampleSeq)
        assertEquals(2L, reboot.sample?.lowEvidence?.firstSampleSeq)
        assertEquals(500L, reboot.sample?.lowEvidence?.firstMonotonicMs)
        assertNull(reboot.reminder)
    }

    @Test fun newLowEpisodeAfterChargingAndRebootUsesFreshMonotonicWindow() {
        val first = BatteryEngine.evaluate(BatteryState(), reading(30, 100_000), "ep-1")
        val charged = BatteryEngine.evaluate(first.state, reading(31, 101_000, charging = true), "ignored")
        val next = BatteryEngine.evaluate(charged.state, reading(30, 500, boot = "boot-b"), "ep-2")
        assertEquals("ep-2", next.sample?.episodeId)
        assertEquals(500L, next.sample?.lowEvidence?.firstMonotonicMs)
        assertEquals(3L, next.sample?.sampleSeq)
    }

    @Test fun changingWallClockDoesNotCreateFakeMonotonicDuration() {
        val first = BatteryEngine.evaluate(BatteryState(), reading(30, 1_000), "ep-1")
        val second = BatteryEngine.evaluate(first.state,
            reading(30, 2_000, wall = base + 24 * 60 * 60_000L), "ignored")
        assertEquals(1_000L, second.sample!!.lowEvidence!!.currentMonotonicMs -
            second.sample!!.lowEvidence!!.firstMonotonicMs)
    }

    @Test fun pendingQueueKeepsOnlyCurrentSnapshotAndRevocationClearsIt() {
        val first = BatteryEngine.evaluate(BatteryState(), reading(30, 1_000), "ep-1")
        val resolved = BatteryEngine.evaluate(first.state, reading(30, 2_000, charging = true), "ignored")
        var queue = BatteryPendingQueue().replace(first.sample!!)
        queue = queue.replace(resolved.sample!!)
        assertEquals("resolved", queue.current?.phase)
        assertEquals(2L, queue.current?.sampleSeq)
        assertNull(queue.current?.lowEvidence)
        assertNull(queue.clear().current)
    }

    @Test fun invalidBatteryValueNeverCreatesAnEpisode() {
        for (value in listOf(-1, 101)) {
            try { BatteryEngine.evaluate(BatteryState(), reading(value, 1_000), "ep-1")
                fail("invalid battery accepted")
            } catch (_: IllegalArgumentException) { }
        }
    }

    @Test fun stopAcknowledgementAdvancesVersionAndCannotClearAStillActiveShare() {
        assertTrue(BatteryConsentFence.canConfirmStop(1, 2, false, true))
        assertTrue(BatteryConsentFence.canConfirmStop(2, 2, false, true))
        // A server stop may have succeeded before the local acknowledgement
        // was lost; a retry legitimately returns a later consent version.
        assertTrue(BatteryConsentFence.canConfirmStop(1, 3, false, true))
        assertFalse(BatteryConsentFence.canConfirmStop(2, 1, false, true))
        assertFalse(BatteryConsentFence.canConfirmStop(1, 2, true, true))
        assertFalse(BatteryConsentFence.canConfirmStop(1, 2, false, false))
    }
}
