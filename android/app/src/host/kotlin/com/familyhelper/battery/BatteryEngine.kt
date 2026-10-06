// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.battery

/** Android-free battery transition. Monotonic evidence is valid only within one
 * boot epoch; the wall clock is recorded for display, never for duration.
 */
data class BatteryReading(
    val percent: Int,
    val charging: Boolean,
    val observedAt: Long,
    val elapsedRealtimeMs: Long,
    val bootEpoch: String,
)

data class LowEvidence(
    val bootEpoch: String,
    val firstMonotonicMs: Long,
    val currentMonotonicMs: Long,
    val firstSampleSeq: Long,
    val currentSampleSeq: Long,
)

data class BatterySample(
    val batteryPercent: Int,
    val charging: Boolean,
    val observedAt: Long,
    val episodeId: String,
    val sampleSeq: Long,
    val phase: String,
    val severity: String,
    val lowEvidence: LowEvidence? = null,
)

data class BatteryState(
    val episodeId: String? = null,
    val active: Boolean = false,
    val sampleSeq: Long = 0,
    val bootEpoch: String? = null,
    val firstLowElapsedMs: Long? = null,
    val firstLowSeq: Long? = null,
    val lastElapsedMs: Long? = null,
    val reminderLevel: Int = 0,
)

/** Fresh approval starts fresh low-battery evidence without moving the
 * anti-replay sequence backwards or reviving a resolved server episode.
 */
object BatteryConsentRestart {
    fun forNewGeneration(state: BatteryState) = state.copy(
        episodeId = null, active = false, bootEpoch = null,
        firstLowElapsedMs = null, firstLowSeq = null, lastElapsedMs = null,
        reminderLevel = 0,
    )
}

data class BatteryDecision(
    val state: BatteryState,
    val sample: BatterySample?,
    val reminder: String?,
)

data class BatteryPendingQueue(val current: BatterySample? = null) {
    fun replace(sample: BatterySample): BatteryPendingQueue {
        if (current != null && sample.sampleSeq <= current.sampleSeq) return this
        // Only the newest snapshot is retained. A charging snapshot discards
        // every pending low/critical upload for the prior episode.
        return BatteryPendingQueue(sample)
    }
    fun clear() = BatteryPendingQueue()
}

object BatteryEngine {
    fun evaluate(state: BatteryState, reading: BatteryReading, newEpisodeId: String): BatteryDecision {
        require(reading.percent in 0..100 && reading.observedAt >= 0 &&
            reading.elapsedRealtimeMs >= 0 && reading.bootEpoch.isNotBlank()) { "Invalid battery reading" }
        require(state.sampleSeq < Long.MAX_VALUE) { "Battery sample sequence exhausted" }
        require(newEpisodeId.matches(Regex("[A-Za-z0-9-]{1,64}"))) { "Invalid episode ID" }
        val seq = state.sampleSeq + 1
        val low = !reading.charging && reading.percent <= 30
        val severity = if (reading.percent <= 15) "critical" else "low"
        if (!low) {
            val id = state.episodeId ?: newEpisodeId
            val reminder = if (state.active) "resolved" else null
            val next = state.copy(episodeId = if (state.active) id else null, active = false,
                sampleSeq = seq, lastElapsedMs = reading.elapsedRealtimeMs,
                firstLowElapsedMs = null, firstLowSeq = null, reminderLevel = 0)
            return BatteryDecision(next, BatterySample(reading.percent, reading.charging,
                reading.observedAt, id, seq, "resolved", severity), reminder)
        }

        val newEpisode = !state.active
        val id = if (newEpisode) newEpisodeId else state.episodeId!!
        val rebooted = state.active && state.bootEpoch != reading.bootEpoch
        require(newEpisode || rebooted || state.lastElapsedMs == null ||
            reading.elapsedRealtimeMs > state.lastElapsedMs) { "Monotonic time did not increase" }
        val firstElapsed = if (newEpisode || rebooted) reading.elapsedRealtimeMs else state.firstLowElapsedMs!!
        val firstSeq = if (newEpisode || rebooted) seq else state.firstLowSeq!!
        val level = if (reading.percent <= 15) 2 else 1
        val reminder = when {
            newEpisode -> if (level == 2) "critical" else "low"
            level > state.reminderLevel -> "critical"
            else -> null
        }
        val next = state.copy(episodeId = id, active = true, sampleSeq = seq,
            bootEpoch = reading.bootEpoch, firstLowElapsedMs = firstElapsed,
            firstLowSeq = firstSeq, lastElapsedMs = reading.elapsedRealtimeMs,
            reminderLevel = maxOf(state.reminderLevel, level))
        val evidence = LowEvidence(reading.bootEpoch, firstElapsed, reading.elapsedRealtimeMs,
            firstSeq, seq)
        return BatteryDecision(next, BatterySample(reading.percent, reading.charging,
            reading.observedAt, id, seq, "low", severity, evidence), reminder)
    }
}

/** A stop is complete only after the server advances the same consent
 * generation. Never clear a pending stop while local sharing is still on.
 */
object BatteryConsentFence {
    fun canConfirmStop(localVersion: Int, serverVersion: Int, sharing: Boolean,
                       pending: Boolean): Boolean =
        pending && !sharing && localVersion > 0 && serverVersion >= localVersion
}
