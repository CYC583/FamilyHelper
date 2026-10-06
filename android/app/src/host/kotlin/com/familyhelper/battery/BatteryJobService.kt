// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.battery

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.content.BroadcastReceiver
import android.content.Intent
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.Future

/** Opportunistic system work, not an exact alarm or an always-on foreground
 * service. Battery reminders remain local when Firebase is unavailable.
 */
class BatteryJobService : JobService() {
    private val worker = Executors.newSingleThreadExecutor()
    private var running: Future<*>? = null

    override fun onStartJob(params: JobParameters): Boolean {
        running = worker.submit {
            try { BatteryRunner.sampleAndSync(applicationContext) }
            catch (error: Exception) {
                BatteryStore(applicationContext).markSyncError("電量檢查暫時失敗，稍後重試")
            }
            // Same opportunistic 15-minute window drives local reminders; a
            // failure here must never block the battery path above.
            try { com.familyhelper.care.CareRunner.run(applicationContext) } catch (_: Exception) {}
            finally { jobFinished(params, false) }
        }
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        running?.cancel(true)
        return true // Android may retry this job later.
    }

    override fun onDestroy() {
        worker.shutdownNow()
        super.onDestroy()
    }
}

object BatteryScheduler {
    private const val JOB_ID = 4301
    private const val PERIOD_MS = 15 * 60_000L

    fun ensure(context: Context): Boolean {
        val scheduler = context.getSystemService(JobScheduler::class.java)
        if (scheduler.allPendingJobs.any { it.id == JOB_ID }) return true
        val job = JobInfo.Builder(JOB_ID, ComponentName(context, BatteryJobService::class.java))
            .setPeriodic(PERIOD_MS)
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_NONE)
            .setPersisted(true) // Host-only RECEIVE_BOOT_COMPLETED was approved.
            .build()
        return scheduler.schedule(job) == JobScheduler.RESULT_SUCCESS
    }
}

class BatteryBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            BatteryScheduler.ensure(context)
            // Geofences are cleared by a reboot; restore grandma's saved places.
            try { com.familyhelper.care.PlaceAlerts.register(context) } catch (_: Exception) {}
            try { com.familyhelper.care.StatusJob.restore(context) } catch (_: Exception) {}
        }
    }
}

object BatteryRunner {
    fun sampleAndSync(context: Context): BatteryDecision? {
        val reading = BatterySampler.read(context) ?: return null
        val store = BatteryStore(context)
        val decision = store.evaluateAndAccept(reading, "ep-${UUID.randomUUID()}")
        BatteryNotifier.present(context, decision, store)
        BatterySync.retry(context)
        return decision
    }
}
