// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.battery

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONObject

/** Host-only durable state. commit() is deliberate: sequence and queue must be
 * on disk before a background upload can begin or the process may be killed.
 */
class BatteryStore(context: Context) {
    companion object {
        private val sampleLock = Any()
        const val DISCLOSURE_VERSION = 2
    }
    private val prefs: SharedPreferences = context.getSharedPreferences("battery_care_v1", Context.MODE_PRIVATE)

    init {
        // A pre-upgrade local approval did not disclose events or family alerts.
        if (prefs.getBoolean("shareEnabled", false) &&
            prefs.getInt("disclosureVersion", 0) != DISCLOSURE_VERSION) {
            stopSharingLocally()
        }
    }

    @Synchronized fun state() = BatteryState(
        episodeId = prefs.getString("episodeId", null),
        active = prefs.getBoolean("active", false),
        sampleSeq = prefs.getLong("sampleSeq", 0),
        bootEpoch = prefs.getString("bootEpoch", null),
        firstLowElapsedMs = optionalLong("firstLowElapsedMs"),
        firstLowSeq = optionalLong("firstLowSeq"),
        lastElapsedMs = optionalLong("lastElapsedMs"),
        reminderLevel = prefs.getInt("reminderLevel", 0),
    )

    fun evaluateAndAccept(reading: BatteryReading, episodeId: String): BatteryDecision = synchronized(sampleLock) {
        val decision = BatteryEngine.evaluate(state(), reading, episodeId)
        accept(decision)
        decision
    }

    private fun optionalLong(key: String) = if (prefs.contains(key)) prefs.getLong(key, 0) else null

    @Synchronized fun accept(decision: BatteryDecision) {
        val next = decision.state
        val edit = prefs.edit()
            .putString("episodeId", next.episodeId)
            .putBoolean("active", next.active)
            .putLong("sampleSeq", next.sampleSeq)
            .putString("bootEpoch", next.bootEpoch)
            .putInt("reminderLevel", next.reminderLevel)
        fun putOptional(key: String, value: Long?) {
            if (value == null) edit.remove(key) else edit.putLong(key, value)
        }
        putOptional("firstLowElapsedMs", next.firstLowElapsedMs)
        putOptional("firstLowSeq", next.firstLowSeq)
        putOptional("lastElapsedMs", next.lastElapsedMs)
        decision.sample?.let { sample ->
            edit.putInt("percent", sample.batteryPercent)
                .putBoolean("charging", sample.charging)
                .putLong("observedAt", sample.observedAt)
                .putString("phase", sample.phase)
            if (shareEnabled()) edit.putString("pending", encode(sample).toString())
        }
        if (!edit.commit()) throw IllegalStateException("無法儲存電量取樣")
    }

    @Synchronized fun pending(): BatterySample? {
        val raw = prefs.getString("pending", null) ?: return null
        return try {
            val json = JSONObject(raw)
            val evidence = json.optJSONObject("lowEvidence")?.let {
                LowEvidence(it.getString("bootEpoch"), it.getLong("firstMonotonicMs"),
                    it.getLong("currentMonotonicMs"), it.getLong("firstSampleSeq"),
                    it.getLong("currentSampleSeq"))
            }
            BatterySample(json.getInt("batteryPercent"), json.getBoolean("charging"),
                json.getLong("observedAt"), json.getString("episodeId"),
                json.getLong("sampleSeq"), json.getString("phase"),
                json.getString("severity"), evidence)
        } catch (_: Exception) {
            prefs.edit().remove("pending").commit()
            null
        }
    }

    private fun encode(sample: BatterySample) = JSONObject().apply {
        put("batteryPercent", sample.batteryPercent)
        put("charging", sample.charging)
        put("observedAt", sample.observedAt)
        put("episodeId", sample.episodeId)
        put("sampleSeq", sample.sampleSeq)
        put("phase", sample.phase)
        put("severity", sample.severity)
        sample.lowEvidence?.let { e ->
            put("lowEvidence", JSONObject().apply {
                put("bootEpoch", e.bootEpoch)
                put("firstMonotonicMs", e.firstMonotonicMs)
                put("currentMonotonicMs", e.currentMonotonicMs)
                put("firstSampleSeq", e.firstSampleSeq)
                put("currentSampleSeq", e.currentSampleSeq)
            })
        }
    }

    @Synchronized fun setShareConsent(hostUid: String, version: Int, enabled: Boolean,
        disclosureVersion: Int) = synchronized(sampleLock) {
        require(hostUid.isNotBlank() && version > 0 &&
            (!enabled || disclosureVersion == DISCLOSURE_VERSION))
        val edit = prefs.edit().putString("hostUid", hostUid)
            .putInt("consentVersion", version).putBoolean("shareEnabled", enabled)
            .putInt("disclosureVersion", disclosureVersion)
        if (enabled) {
            val fresh = BatteryConsentRestart.forNewGeneration(state())
            edit.remove("episodeId").putBoolean("active", fresh.active)
                .putLong("sampleSeq", fresh.sampleSeq).remove("bootEpoch")
                .remove("firstLowElapsedMs").remove("firstLowSeq")
                .remove("lastElapsedMs").putInt("reminderLevel", fresh.reminderLevel)
                .remove("pending").remove("lastSyncedAt").remove("syncError")
                .putBoolean("revokePending", false)
        } else edit.remove("pending")
        if (!edit.commit()) throw IllegalStateException("無法儲存電量分享選擇")
    }

    @Synchronized fun stopSharingLocally() {
        if (!prefs.edit().putBoolean("shareEnabled", false).remove("pending")
                .putBoolean("revokePending", true).commit()) {
            throw IllegalStateException("無法停止本機電量分享")
        }
    }

    /** Generation check and stop are atomic with a new local approval. */
    @Synchronized fun stopSharingIfCurrentVersion(version: Int): Boolean = synchronized(sampleLock) {
        if (!BatterySyncFailurePolicy.mayStopCurrentShare(version, consentVersion(), shareEnabled())) {
            false
        } else {
            stopSharingLocally()
            markSyncError("電量分享已停止，請開啟 App 重新確認")
            true
        }
    }

    @Synchronized fun markConsentSynced(version: Int) {
        if (BatteryConsentFence.canConfirmStop(prefs.getInt("consentVersion", 0),
                version, shareEnabled(), prefs.getBoolean("revokePending", false))) {
            prefs.edit().putInt("consentVersion", version)
                .putBoolean("revokePending", false).commit()
        }
    }

    @Synchronized fun markSynced(sampleSeq: Long, at: Long) {
        if (pending()?.sampleSeq == sampleSeq) {
            prefs.edit().remove("pending").putLong("lastSyncedAt", at)
                .remove("syncError").commit()
        }
    }

    /** Discard an obsolete response only if that exact sample is still queued;
     * a newer snapshot accepted while the request was in flight must survive.
     */
    @Synchronized fun discardRejected(sampleSeq: Long) {
        if (pending()?.sampleSeq == sampleSeq) {
            if (!prefs.edit().remove("pending")
                    .putString("syncError", "一筆過期電量資料已略過；後續取樣會繼續")
                    .commit()) throw IllegalStateException("無法略過過期電量資料")
        }
    }

    @Synchronized fun markSyncError(reason: String) {
        prefs.edit().putString("syncError", reason.take(120)).commit()
    }

    @Synchronized fun shareEnabled() = prefs.getBoolean("shareEnabled", false) &&
        prefs.getInt("disclosureVersion", 0) == DISCLOSURE_VERSION
    @Synchronized fun consentVersion() = prefs.getInt("consentVersion", 0)
    @Synchronized fun hostUid() = prefs.getString("hostUid", null)
    @Synchronized fun voiceEnabled() = prefs.getBoolean("voiceEnabled", true)
    @Synchronized fun toneEnabled() = prefs.getBoolean("toneEnabled", true)
    @Synchronized fun setVoiceEnabled(enabled: Boolean) {
        if (!prefs.edit().putBoolean("voiceEnabled", enabled).commit())
            throw IllegalStateException("無法儲存朗讀設定")
    }
    @Synchronized fun setToneEnabled(enabled: Boolean) {
        if (!prefs.edit().putBoolean("toneEnabled", enabled).commit())
            throw IllegalStateException("無法儲存提示聲設定")
    }

    @Synchronized fun acknowledgeLocal() {
        prefs.edit().putLong("acknowledgedSeq", prefs.getLong("sampleSeq", 0))
            .putString("acknowledgedEpisodeId", prefs.getString("episodeId", null)).commit()
    }

    @Synchronized fun snapshot(): Map<String, Any?> = mapOf(
        "batteryPercent" to if (prefs.contains("percent")) prefs.getInt("percent", 0) else null,
        "charging" to prefs.getBoolean("charging", false),
        "observedAt" to if (prefs.contains("observedAt")) prefs.getLong("observedAt", 0) else null,
        "phase" to prefs.getString("phase", null),
        "sampleSeq" to prefs.getLong("sampleSeq", 0),
        "episodeId" to prefs.getString("episodeId", null),
        "shareEnabled" to shareEnabled(),
        "consentVersion" to consentVersion(),
        "disclosureVersion" to prefs.getInt("disclosureVersion", 0),
        "revokePending" to prefs.getBoolean("revokePending", false),
        "voiceEnabled" to voiceEnabled(),
        "toneEnabled" to toneEnabled(),
        "lastSyncedAt" to if (prefs.contains("lastSyncedAt")) prefs.getLong("lastSyncedAt", 0) else null,
        "syncError" to prefs.getString("syncError", null),
        "acknowledgedSeq" to prefs.getLong("acknowledgedSeq", 0),
        "acknowledgedEpisodeId" to prefs.getString("acknowledgedEpisodeId", null),
        "lastVoiceStartedAt" to if (prefs.contains("lastVoiceStartedAt")) prefs.getLong("lastVoiceStartedAt", 0) else null,
        "lastVoiceError" to prefs.getString("lastVoiceError", null),
        "lastNotificationAt" to if (prefs.contains("lastNotificationAt")) prefs.getLong("lastNotificationAt", 0) else null,
        "lastNotificationError" to prefs.getString("lastNotificationError", null),
    )

    @Synchronized fun voiceResult(startedAt: Long?, error: String?) {
        val edit = prefs.edit()
        if (startedAt != null) edit.putLong("lastVoiceStartedAt", startedAt).remove("lastVoiceError")
        else edit.putString("lastVoiceError", error ?: "朗讀未能開始")
        edit.commit()
    }

    @Synchronized fun notificationResult(postedAt: Long?, error: String?) {
        val edit = prefs.edit()
        if (postedAt != null) edit.putLong("lastNotificationAt", postedAt).remove("lastNotificationError")
        else edit.putString("lastNotificationError", error ?: "通知未能顯示")
        edit.commit()
    }
}
