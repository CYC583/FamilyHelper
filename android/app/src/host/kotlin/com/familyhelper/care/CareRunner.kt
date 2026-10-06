// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.care

import android.app.NotificationManager
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import com.familyhelper.reminders.AndroidReminderStore
import com.familyhelper.reminders.DueReminder
import com.familyhelper.reminders.ReminderCoordinator
import com.familyhelper.reminders.ReminderItem
import com.familyhelper.reminders.ReminderSettingsParser
import com.google.android.gms.tasks.Tasks
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.database.FirebaseDatabase
import com.google.firebase.functions.FirebaseFunctions
import com.google.firebase.functions.FirebaseFunctionsException
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.time.Instant
import java.time.LocalDate
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** One opportunistic pass: reminders, snoozes, morning card, reply upload and
 * sound status. Runs on a worker thread from JobScheduler or the open app.
 * It never signs in a new identity and never claims exact delivery times.
 */
object CareRunner {
    private val lock = Any()

    fun run(context: Context, allowNetwork: Boolean = true) = synchronized(lock) {
        val app = context.applicationContext
        val care = CareStore(app)
        val reminders = AndroidReminderStore(app)
        val uid = try { FirebaseAuth.getInstance().currentUser?.uid } catch (_: Exception) { null }
        val now = System.currentTimeMillis()
        val db = care.databaseUrl()?.let { url -> try { FirebaseDatabase.getInstance(url) } catch (_: Exception) { null } }
        if (reminders.isEnabled() && uid != null && uid == reminders.hostUid()) {
            if (allowNetwork && db != null) refreshWeather(db, uid, care)
            val coordinator = ReminderCoordinator(reminders,
                source = { if (allowNetwork && db != null) readReminderPlan(db, uid) else null },
                presenter = { due -> CareNotifier.presentReminder(app, due, care) })
            val status = coordinator.run(uid, now)
            care.noteEvent("plan", status.name)
            if (allowNetwork && db != null) {
                try {
                    val raw = Tasks.await(db.getReference("care/$uid/voiceProfiles").get(), 10, TimeUnit.SECONDS).value
                    care.saveVoiceProfiles(raw as? Map<*, *> ?: emptyMap<Any, Any>())
                } catch (_: Exception) { /* keep last profiles */ }
            }
            if (allowNetwork) {
                val wanted = ((reminders.cachedSettings()?.items?.mapNotNull { it.voiceId } ?: emptyList()) +
                    care.voiceProfiles().mapNotNull { it.voiceId }).toSet()
                try { ReminderVoices.sync(app, uid, wanted) } catch (_: Exception) {}
            }
            presentSnoozes(app, care, now)
            runMorning(app, care, now, allowNetwork)
        }
        if (allowNetwork && uid != null && reminders.isEnabled() && uid == reminders.hostUid() &&
            reminders.disclosure() >= 2) {
            try { uploadReminderStatus(reminders, care) } catch (_: Exception) {}
        }
        if (allowNetwork && uid != null && db != null && uid == care.appHostUid()) {
            try { MessageAnnouncer.run(app, uid, db, care) } catch (_: Exception) {}
        }
        if (allowNetwork && uid != null && uid == care.companionHost()) {
            uploadResponses(uid, care)
            reportSound(app, uid, care, now)
        }
    }

    /** v2 plan when present, else the v1 daily list. */
    private fun readReminderPlan(db: FirebaseDatabase, uid: String) = try {
        val v2 = Tasks.await(db.getReference("care/$uid/settings/reminderPlan").get(), 10, TimeUnit.SECONDS).value
        ReminderSettingsParser.parse(v2 ?: Tasks.await(
            db.getReference("care/$uid/settings/reminders").get(), 10, TimeUnit.SECONDS).value)
    } catch (e: Exception) {
        android.util.Log.w("FHCare", "reminder plan read failed: ${e.javaClass.simpleName}")
        throw e
    }

    private fun refreshWeather(db: FirebaseDatabase, uid: String, care: CareStore) {
        try {
            val raw = Tasks.await(db.getReference("care/$uid/settings/weather").get(),
                10, TimeUnit.SECONDS).value as? Map<*, *> ?: return
            val city = raw["city"] as? Map<*, *> ?: return
            care.saveWeather(city["name"] as? String ?: return, (city["latitude"] as? Number ?: return).toDouble(),
                (city["longitude"] as? Number ?: return).toDouble(), raw["morningTime"] as? String ?: return,
                (raw["version"] as? Number)?.toInt() ?: 0)
        } catch (_: Exception) { /* Keep the last verified plan; morning falls back to the quote. */ }
    }

    private fun presentSnoozes(context: Context, care: CareStore, now: Long) {
        val snoozes = care.snoozes()
        for (i in 0 until snoozes.length()) {
            val item = snoozes.getJSONObject(i)
            if (item.optLong("dueAt") > now) continue
            val due = DueReminder(item.getString("key"), ReminderItem(item.getString("type"),
                item.getString("time"), item.optString("text")), item.optLong("dueAt"))
            // Snoozed long ago (phone off overnight) is dropped instead of replayed.
            if (now - due.scheduledAtMs <= 2 * 60 * 60_000L) CareNotifier.presentReminder(context, due, care)
            care.removeSnooze(due.key)
        }
    }

    private fun runMorning(context: Context, care: CareStore, now: Long, allowNetwork: Boolean) {
        val key = MorningPolicy.dueKey(now, care.morningTime(), care.lastMorningKey()) ?: return
        val city = care.weatherCity()
        val weather = if (allowNetwork && city != null) fetchWeather(city, care.weatherLat(), care.weatherLon(), now) else null
        val rotation = care.voiceProfiles().filter { it.joinWeather && it.voiceId != null &&
            ReminderVoices.file(context, it.voiceId).exists() }
        val today = rotation.firstOrNull { it.uid == WeatherRotation.pick(TaiwanMarket.day(now), rotation.map { p -> p.uid }) }
        val script = MorningScript.compose(weather, care.quoteFor(TaiwanMarket.day(now)), city != null, greeted = today != null)
        care.markMorning(key, CareNotifier.presentMorning(context, script, care, today?.voiceId))
    }

    /** Open-Meteo forecast for today's Taipei date only; anything else is null. */
    fun fetchWeather(city: String, lat: Double, lon: Double, now: Long): MorningWeather? = try {
        val url = URL("https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon" +
            "&current=temperature_2m,weather_code&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max" +
            "&timezone=Asia%2FTaipei&forecast_days=1")
        val connection = (url.openConnection() as HttpURLConnection).apply { connectTimeout = 8000; readTimeout = 8000 }
        val body = try { connection.inputStream.bufferedReader().use { it.readText().take(64_000) } } finally { connection.disconnect() }
        val json = JSONObject(body)
        val current = json.getJSONObject("current")
        val daily = json.getJSONObject("daily")
        val today = TaiwanMarket.day(now).toString()
        val observed = Instant.parse("${current.getString("time")}:00Z").toEpochMilli() - 8 * 3600_000L
        if (json.optString("timezone") != "Asia/Taipei" || daily.getJSONArray("time").getString(0) != today ||
            kotlin.math.abs(now - observed) > 2 * 3600_000L) null
        else MorningWeather(city, current.getDouble("temperature_2m"), current.getInt("weather_code"),
            daily.getJSONArray("temperature_2m_max").getDouble(0), daily.getJSONArray("temperature_2m_min").getDouble(0),
            daily.optJSONArray("precipitation_probability_max")?.takeIf { !it.isNull(0) }?.getInt(0))
    } catch (_: Exception) { null }

    private val functions get() = FirebaseFunctions.getInstance("asia-east1")

    /** Tells family which plan version this phone has and what played. */
    private fun uploadReminderStatus(reminders: AndroidReminderStore, care: CareStore) {
        val version = reminders.cachedSettings()?.version ?: return
        val queue = care.deliveryQueue()
        if (queue.length() == 0 && care.syncedPlanVersion() == version) return
        val rows = (0 until queue.length()).map { queue.getJSONObject(it) }.map {
            mapOf("key" to it.getString("key"), "state" to it.getString("state"), "at" to it.getLong("at"))
        }
        Tasks.await(functions.getHttpsCallable("reportReminderStatus").call(mapOf(
            "planVersion" to version, "deliveries" to rows)), 15, TimeUnit.SECONDS)
        care.markSyncedPlan(version)
        care.dropDeliveries(rows.size)
    }

    private fun uploadResponses(uid: String, care: CareStore) {
        if (!care.companionItem("responses")) { care.clearQueue(); return }
        val queue = care.queue()
        var sent = 0
        for (i in 0 until queue.length()) {
            val row = queue.getJSONObject(i)
            try {
                Tasks.await(functions.getHttpsCallable("recordReminderResponse").call(mapOf(
                    "date" to row.getString("date"), "type" to row.getString("type"), "time" to row.getString("time"),
                    "response" to row.getString("response"), "respondedAt" to row.getLong("respondedAt"),
                    "consentVersion" to care.companionVersion())), 15, TimeUnit.SECONDS)
                sent++
            } catch (error: Exception) {
                val code = ((error as? java.util.concurrent.ExecutionException)?.cause as? FirebaseFunctionsException)?.code
                // Consent/format rejections are final for that row; anything else retries later.
                if (code == FirebaseFunctionsException.Code.FAILED_PRECONDITION ||
                    code == FirebaseFunctionsException.Code.INVALID_ARGUMENT) { sent++; continue }
                care.noteEvent("sync", "提醒回覆尚未同步，稍後重試"); break
            }
        }
        if (sent > 0) care.dropQueued(sent)
    }

    fun currentSound(context: Context): SoundState {
        val audio = context.getSystemService(AudioManager::class.java)
        val manager = context.getSystemService(NotificationManager::class.java)
        return SoundPolicy.classify(audio.ringerMode, manager.currentInterruptionFilter,
            audio.getStreamVolume(AudioManager.STREAM_MUSIC))
    }

    /** Reports only on change, or every 30 minutes while quiet so the server can
     * measure a continuous episode. Never reports app names or audio content.
     */
    private fun reportSound(context: Context, uid: String, care: CareStore, now: Long) {
        if (!care.companionItem("sound")) return
        val state = currentSound(context)
        val signature = "${state.ringer}:${state.dnd}:${state.mediaZero}"
        val due = signature != care.soundSignature() || (state.quiet && now - care.soundReportedAt() >= 25 * 60_000L)
        if (!due) return
        try {
            Tasks.await(functions.getHttpsCallable("reportSoundStatus").call(mapOf(
                "ringer" to state.ringer, "dnd" to state.dnd, "mediaZero" to state.mediaZero,
                "observedAt" to now, "consentVersion" to care.companionVersion())), 15, TimeUnit.SECONDS)
            care.markSoundReported(signature, now)
        } catch (_: Exception) { care.noteEvent("sync", "聲音狀態尚未同步，稍後重試") }
    }
}

/** Notification buttons. Replies are stored locally first; upload is retried. */
class CareActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        Executors.newSingleThreadExecutor().execute {
            try {
                val store = CareStore(context)
                val now = System.currentTimeMillis()
                when (intent.action) {
                    CareNotifier.ACTION_REMINDER -> {
                        val key = intent.getStringExtra("key") ?: return@execute
                        val type = intent.getStringExtra("type") ?: return@execute
                        val time = intent.getStringExtra("time") ?: return@execute
                        val response = intent.getStringExtra("response") ?: return@execute
                        CareNotifier.cancel(context, intent.getIntExtra("id", CareNotifier.reminderId(key)))
                        val date = key.substringBefore(':').takeIf { runCatching { LocalDate.parse(it) }.isSuccess }
                            ?: TaiwanMarket.day(now).toString()
                        CareActions.respond(context, store, date, key, type, time, intent.getStringExtra("text").orEmpty(), response, now)
                    }
                    CareNotifier.ACTION_REST -> {
                        CareNotifier.cancelRest(context)
                        if (intent.getStringExtra("response") == "later") store.snoozeRest(now + RestReminderPolicy.COOLDOWN_MS)
                        else store.snoozeRest(now + RestReminderPolicy.THRESHOLD_MS)
                        ScreenTimeMonitor.reschedule(context)
                    }
                }
            } finally { pending.finish() }
        }
    }
}

object CareActions {
    const val SNOOZE_MS = 10 * 60_000L

    /** "Later" re-shows once after about ten minutes; it is grandma's choice,
     * not the automatic market-hours deferral, so medicine may also be snoozed.
     */
    fun respond(context: Context, store: CareStore, date: String, key: String, type: String, time: String,
                text: String, response: String, now: Long) {
        if (response !in setOf("done", "later", "skip")) return
        store.recordResponse(date, type, time, response, now)
        if (response == "later") {
            store.addSnooze(key, type, time, text, now + SNOOZE_MS)
            CareKickJob.schedule(context, SNOOZE_MS)
        } else store.removeSnooze(key)
        CareKickJob.schedule(context, 0)
    }
}

class CareKickJob : JobService() {
    private val worker = Executors.newSingleThreadExecutor()
    override fun onStartJob(params: JobParameters): Boolean {
        worker.execute {
            try { CareRunner.run(applicationContext) } catch (_: Exception) {}
            finally { jobFinished(params, false) }
        }
        return true
    }
    override fun onStopJob(params: JobParameters) = true
    override fun onDestroy() { worker.shutdownNow(); super.onDestroy() }

    companion object {
        private const val NOW_ID = 4420
        private const val LATER_ID = 4421
        fun schedule(context: Context, delayMs: Long) {
            val scheduler = context.getSystemService(JobScheduler::class.java)
            val builder = JobInfo.Builder(if (delayMs <= 0) NOW_ID else LATER_ID,
                ComponentName(context, CareKickJob::class.java))
                .setMinimumLatency(delayMs.coerceAtLeast(0))
                .setOverrideDeadline(delayMs.coerceAtLeast(0) + 5 * 60_000L)
            if (delayMs <= 0) builder.setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            scheduler.schedule(builder.build())
        }
    }
}
