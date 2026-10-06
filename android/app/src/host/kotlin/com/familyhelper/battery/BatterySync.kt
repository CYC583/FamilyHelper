// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.battery

import android.content.Context
import com.familyhelper.BuildConfig
import com.google.android.gms.tasks.Tasks
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.functions.FirebaseFunctions
import com.google.firebase.functions.FirebaseFunctionsException
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit

/** Uploads only the newest host snapshot with the same native Firebase Auth
 * identity used by FlutterFire. Never signs in a new background identity.
 */
object BatterySync {
    private val functions: FirebaseFunctions get() = FirebaseFunctions.getInstance("asia-east1")

    fun configureDebugEmulator(host: String, authPort: Int, functionsPort: Int) {
        require(BuildConfig.DEBUG) { "Release APK cannot use Firebase Emulators" }
        require(host == "10.0.2.2" || host == "127.0.0.1") { "Only local Emulator endpoints are allowed" }
        FirebaseAuth.getInstance().useEmulator(host, authPort)
        functions.useEmulator(host, functionsPort)
    }

    /** Call on a worker thread only. The caller owns retry scheduling. */
    @Synchronized fun retry(context: Context): Boolean {
        val store = BatteryStore(context.applicationContext)
        if (!store.shareEnabled()) return false
        val sample = store.pending() ?: return true
        val submittedVersion = store.consentVersion()
        val expectedUid = store.hostUid()
        val currentUid = FirebaseAuth.getInstance().currentUser?.uid
        if (expectedUid.isNullOrBlank() || expectedUid != currentUid) {
            store.markSyncError("裝置身分尚未確認，請開啟 App")
            return false
        }
        val evidence = sample.lowEvidence?.let { e ->
            mapOf("bootEpoch" to e.bootEpoch, "firstMonotonicMs" to e.firstMonotonicMs,
                "currentMonotonicMs" to e.currentMonotonicMs,
                "firstSampleSeq" to e.firstSampleSeq, "currentSampleSeq" to e.currentSampleSeq)
        }
        val snapshot = mutableMapOf<String, Any>(
            "batteryPercent" to sample.batteryPercent, "charging" to sample.charging,
            "observedAt" to sample.observedAt, "episodeId" to sample.episodeId,
            "sampleSeq" to sample.sampleSeq, "phase" to sample.phase,
            "severity" to sample.severity,
        )
        if (evidence != null) snapshot["lowEvidence"] = evidence
        return try {
            Tasks.await(functions.getHttpsCallable("reportBatterySample").call(mapOf(
                "sample" to snapshot, "consentVersion" to submittedVersion,
            )), 20, TimeUnit.SECONDS)
            store.markSynced(sample.sampleSeq, System.currentTimeMillis())
            true
        } catch (error: Exception) {
            val cause = if (error is ExecutionException) error.cause else error
            val action = if (cause is FirebaseFunctionsException)
                BatterySyncFailurePolicy.classify(cause.code.name, cause.message)
            else BatteryFailureAction.RETRY
            when (action) {
                BatteryFailureAction.STOP_SHARE -> {
                    if (!store.stopSharingIfCurrentVersion(submittedVersion))
                        store.discardRejected(sample.sampleSeq)
                }
                BatteryFailureAction.DROP_SAMPLE -> store.discardRejected(sample.sampleSeq)
                BatteryFailureAction.RETRY -> store.markSyncError("電量尚未同步，稍後自動重試")
            }
            false
        }
    }
}
