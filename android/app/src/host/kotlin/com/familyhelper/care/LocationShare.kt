// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.care

import android.Manifest
import android.annotation.SuppressLint
import android.app.AppOpsManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.PersistableBundle
import android.os.Process
import androidx.core.content.ContextCompat
import com.familyhelper.R
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.Tasks
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.functions.FirebaseFunctions
import java.time.Instant
import java.time.ZoneId
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

private fun callable(name: String, data: Map<String, Any?>) {
    Tasks.await(FirebaseFunctions.getInstance("asia-east1").getHttpsCallable(name).call(data), 20, TimeUnit.SECONDS)
}

private fun signedInAs(hostUid: String?) =
    hostUid != null && FirebaseAuth.getInstance().currentUser?.uid == hostUid

/** Grandma-approved live location for family. Unlike place alerts this sends
 * coordinates, so it has its own local consent; turning it off stops uploads
 * on this phone first, then the server deletes the last position.
 */
object LocationShare {
    const val DISCLOSURE_VERSION = 1
    private fun prefs(c: Context) = c.applicationContext.getSharedPreferences("care_location_v1", Context.MODE_PRIVATE)

    fun hasPermission(c: Context) = ContextCompat.checkSelfPermission(c, Manifest.permission.ACCESS_FINE_LOCATION) ==
        PackageManager.PERMISSION_GRANTED
    fun hasBackground(c: Context) = PlaceAlerts.hasBackground(c)
    fun enabled(c: Context) = prefs(c).getBoolean("enabled", false)

    fun snapshot(c: Context): Map<String, Any?> {
        val p = prefs(c)
        return mapOf("enabled" to p.getBoolean("enabled", false), "version" to p.getInt("version", 0),
            "permission" to hasPermission(c), "backgroundPermission" to hasBackground(c),
            "lastSentAt" to p.getLong("lastSentAt", 0).takeIf { it > 0 }, "lastError" to p.getString("lastError", null))
    }

    fun enable(c: Context, hostUid: String, version: Int) {
        prefs(c).edit().putBoolean("enabled", true).putInt("version", version).putString("hostUid", hostUid)
            .remove("lastError").commit()
        StatusJob.schedulePeriodic(c)
        StatusJob.runNow(c, location = true, usage = false)
    }

    fun disable(c: Context) {
        prefs(c).edit().putBoolean("enabled", false).commit()
        StatusJob.cancelIfIdle(c)
    }

    /** One fresh position, uploaded. Returns false when nothing was sent. */
    @SuppressLint("MissingPermission")
    fun refresh(c: Context): Boolean {
        val p = prefs(c)
        if (!p.getBoolean("enabled", false) || !hasPermission(c) || !signedInAs(p.getString("hostUid", null))) return false
        return try {
            val client = LocationServices.getFusedLocationProviderClient(c)
            val loc = Tasks.await(client.getCurrentLocation(Priority.PRIORITY_BALANCED_POWER_ACCURACY, null), 25, TimeUnit.SECONDS)
                ?: Tasks.await(client.lastLocation, 5, TimeUnit.SECONDS) ?: run {
                    p.edit().putString("lastError", "暫時找不到位置").commit(); return false
                }
            callable("reportLocation", mapOf("lat" to loc.latitude, "lng" to loc.longitude,
                "accuracy" to loc.accuracy.toDouble(), "at" to loc.time.coerceAtMost(System.currentTimeMillis()),
                "consentVersion" to p.getInt("version", 0)))
            p.edit().putLong("lastSentAt", System.currentTimeMillis()).remove("lastError").commit()
            true
        } catch (_: Exception) {
            p.edit().putString("lastError", "位置沒有送出，稍後會再試").commit()
            false
        }
    }
}

/** Daily minutes per app for family, after grandma's consent and Android's
 * usage-access permission (she turns that on herself in system settings).
 * Only app names and minutes leave the phone.
 */
object AppUsage {
    const val DISCLOSURE_VERSION = 1
    private const val UPLOAD_EVERY_MS = 30 * 60_000L
    private val zone = ZoneId.of("Asia/Taipei")
    private fun prefs(c: Context) = c.applicationContext.getSharedPreferences("care_app_usage_v1", Context.MODE_PRIVATE)

    fun enabled(c: Context) = prefs(c).getBoolean("enabled", false)

    @Suppress("DEPRECATION")
    fun hasPermission(c: Context): Boolean {
        val ops = c.getSystemService(AppOpsManager::class.java)
        val mode = if (Build.VERSION.SDK_INT >= 29) ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS,
            Process.myUid(), c.packageName) else ops.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), c.packageName)
        return mode == AppOpsManager.MODE_ALLOWED
    }

    fun snapshot(c: Context): Map<String, Any?> {
        val p = prefs(c)
        return mapOf("enabled" to p.getBoolean("enabled", false), "version" to p.getInt("version", 0),
            "permission" to hasPermission(c), "lastSentAt" to p.getLong("lastSentAt", 0).takeIf { it > 0 },
            "today" to if (hasPermission(c)) today(c).take(5).map { mapOf("name" to it.first, "minutes" to it.second) } else emptyList<Any>())
    }

    fun enable(c: Context, hostUid: String, version: Int) {
        prefs(c).edit().putBoolean("enabled", true).putInt("version", version).putString("hostUid", hostUid).commit()
        StatusJob.schedulePeriodic(c)
        StatusJob.runNow(c, location = false, usage = true)
    }

    fun disable(c: Context) {
        prefs(c).edit().putBoolean("enabled", false).commit()
        StatusJob.cancelIfIdle(c)
    }

    /** (app name, minutes) for today in Taipei time, longest first. */
    fun today(c: Context, now: Long = System.currentTimeMillis()): List<Pair<String, Int>> {
        val start = Instant.ofEpochMilli(now).atZone(zone).toLocalDate().atStartOfDay(zone).toInstant().toEpochMilli()
        val events = c.getSystemService(UsageStatsManager::class.java).queryEvents(start, now)
        val opened = HashMap<String, Long>()
        val total = HashMap<String, Long>()
        val e = UsageEvents.Event()
        while (events.hasNextEvent()) {
            events.getNextEvent(e)
            when (e.eventType) {
                UsageEvents.Event.ACTIVITY_RESUMED -> opened.putIfAbsent(e.packageName, e.timeStamp)
                UsageEvents.Event.ACTIVITY_PAUSED -> opened.remove(e.packageName)?.let {
                    total[e.packageName] = (total[e.packageName] ?: 0) + (e.timeStamp - it)
                }
            }
        }
        for ((pkg, at) in opened) total[pkg] = (total[pkg] ?: 0) + (now - at)
        val pm = c.packageManager
        return total.mapNotNull { (pkg, ms) ->
            val minutes = (ms / 60_000).toInt()
            if (minutes < 1 || pm.getLaunchIntentForPackage(pkg) == null) return@mapNotNull null
            val name = try { pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString() } catch (_: Exception) { return@mapNotNull null }
            name.replace(Regex("[\\u0000-\\u001f<>]"), "").trim().take(40).takeIf { it.isNotEmpty() }?.let { it to minutes.coerceAtMost(1440) }
        }.groupBy({ it.first }, { it.second }).map { (n, m) -> n to m.sum().coerceAtMost(1440) }
            .sortedByDescending { it.second }.take(30)
    }

    fun upload(c: Context, force: Boolean): Boolean {
        val p = prefs(c)
        if (!p.getBoolean("enabled", false) || !hasPermission(c) || !signedInAs(p.getString("hostUid", null))) return false
        val now = System.currentTimeMillis()
        if (!force && now - p.getLong("lastSentAt", 0) < UPLOAD_EVERY_MS) return false
        return try {
            callable("reportAppUsage", mapOf("date" to Instant.ofEpochMilli(now).atZone(zone).toLocalDate().toString(),
                "apps" to today(c, now).map { mapOf("name" to it.first, "minutes" to it.second) },
                "consentVersion" to p.getInt("version", 0)))
            p.edit().putLong("lastSentAt", now).commit()
            true
        } catch (_: Exception) { false }
    }
}

/** Every 15 minutes (Android's minimum) while either sharing is on; also run
 * right away when family asks through a push.
 */
class StatusJob : JobService() {
    private val worker = Executors.newSingleThreadExecutor()
    override fun onStartJob(params: JobParameters): Boolean {
        val extras = params.extras
        val periodic = params.jobId == PERIODIC_ID
        worker.execute {
            try {
                if (periodic || extras.getBoolean("location", false)) LocationShare.refresh(applicationContext)
                if (periodic || extras.getBoolean("usage", false)) AppUsage.upload(applicationContext, force = !periodic)
            } catch (_: Exception) {} finally { jobFinished(params, false) }
        }
        return true
    }
    override fun onStopJob(params: JobParameters) = true
    override fun onDestroy() { worker.shutdownNow(); super.onDestroy() }

    companion object {
        private const val PERIODIC_ID = 4460
        private const val NOW_ID = 4461

        fun schedulePeriodic(c: Context) {
            c.getSystemService(JobScheduler::class.java).schedule(JobInfo.Builder(PERIODIC_ID, ComponentName(c, StatusJob::class.java))
                .setPeriodic(15 * 60_000L).setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY).setPersisted(true).build())
        }

        fun runNow(c: Context, location: Boolean, usage: Boolean) {
            val extras = PersistableBundle().apply { putBoolean("location", location); putBoolean("usage", usage) }
            c.getSystemService(JobScheduler::class.java).schedule(JobInfo.Builder(NOW_ID, ComponentName(c, StatusJob::class.java))
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY).setExtras(extras).build())
        }

        fun cancelIfIdle(c: Context) {
            if (!LocationShare.enabled(c) && !AppUsage.enabled(c)) c.getSystemService(JobScheduler::class.java).cancel(PERIODIC_ID)
        }

        /** After a reboot or app update, keep the schedule if sharing is on. */
        fun restore(c: Context) { if (LocationShare.enabled(c) || AppUsage.enabled(c)) schedulePeriodic(c) }
    }
}

/** Family pressed "play sound": ring grandma's phone for ten seconds at alarm
 * volume so it can be found, with a notification that can stop it.
 */
object PhoneRinger {
    private const val CHANNEL = "care_find_phone"
    private const val NOTE_ID = 4470
    @Volatile private var player: MediaPlayer? = null
    @Volatile private var restoreVolume: Int? = null

    fun ring(c: Context, by: String, seconds: Int) {
        if (!LocationShare.enabled(c)) return
        stop(c)
        show(c, by)
        val audio = c.getSystemService(AudioManager::class.java)
        restoreVolume = audio.getStreamVolume(AudioManager.STREAM_ALARM)
        try { audio.setStreamVolume(AudioManager.STREAM_ALARM, audio.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0) } catch (_: Exception) {}
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM) ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        try {
            player = MediaPlayer().apply {
                setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
                setDataSource(c, uri)
                isLooping = true
                prepare()
                start()
            }
            Thread.sleep(seconds.coerceIn(3, 15) * 1000L)
        } catch (_: Exception) {
        } finally { stop(c) }
    }

    fun stop(c: Context) {
        player?.let { try { it.stop() } catch (_: Exception) {}; it.release() }
        player = null
        restoreVolume?.let { v ->
            try { c.getSystemService(AudioManager::class.java).setStreamVolume(AudioManager.STREAM_ALARM, v, 0) } catch (_: Exception) {}
        }
        restoreVolume = null
        c.getSystemService(NotificationManager::class.java).cancel(NOTE_ID)
    }

    private fun show(c: Context, by: String) {
        val manager = c.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "家人找手機", NotificationManager.IMPORTANCE_HIGH))
        val stop = PendingIntent.getBroadcast(c, NOTE_ID, Intent(c, RingStopReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        try {
            manager.notify(NOTE_ID, Notification.Builder(c, CHANNEL).setSmallIcon(R.drawable.ic_stat_family)
                .setContentTitle("${by}正在找你的手機").setContentText("手機會響 10 秒，按「停止」可以關掉")
                .addAction(Notification.Action.Builder(null, "停止", stop).build())
                .setContentIntent(stop).setAutoCancel(true).build())
        } catch (_: SecurityException) {}
    }
}

class RingStopReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = PhoneRinger.stop(context)
}

class RingJob : JobService() {
    private val worker = Executors.newSingleThreadExecutor()
    override fun onStartJob(params: JobParameters): Boolean {
        worker.execute {
            try { PhoneRinger.ring(applicationContext, params.extras.getString("by") ?: "家人", params.extras.getInt("seconds", 10)) }
            catch (_: Exception) {} finally { jobFinished(params, false) }
        }
        return true
    }
    override fun onStopJob(params: JobParameters): Boolean { PhoneRinger.stop(applicationContext); return false }
    override fun onDestroy() { worker.shutdownNow(); super.onDestroy() }
    companion object {
        fun schedule(c: Context, by: String, seconds: Int) {
            val extras = PersistableBundle().apply { putString("by", by.take(12)); putInt("seconds", seconds) }
            c.getSystemService(JobScheduler::class.java).schedule(JobInfo.Builder(4471, ComponentName(c, RingJob::class.java))
                .setExtras(extras).setOverrideDeadline(0).build())
        }
    }
}
