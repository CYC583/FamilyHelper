// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.care

import android.Manifest
import android.annotation.SuppressLint
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingEvent
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.Tasks
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.functions.FirebaseFunctions
import com.google.firebase.functions.FirebaseFunctionsException
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Grandma-approved leave/arrive alerts for two saved places. Coordinates stay
 * in this app's private storage; only "home/work, enter/exit, time" is sent.
 */
object PlaceAlerts {
    const val RADIUS_M = 150f
    private fun prefs(c: Context) = c.applicationContext.getSharedPreferences("care_places_v1", Context.MODE_PRIVATE)

    fun hasBackground(c: Context) = ContextCompat.checkSelfPermission(c, Manifest.permission.ACCESS_FINE_LOCATION) ==
        PackageManager.PERMISSION_GRANTED && ContextCompat.checkSelfPermission(c,
        Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED

    fun snapshot(c: Context): Map<String, Any?> {
        val p = prefs(c)
        return mapOf("enabled" to p.getBoolean("enabled", false), "version" to p.getInt("version", 0),
            "homeSet" to p.contains("home_lat"), "workSet" to p.contains("work_lat"),
            "backgroundPermission" to hasBackground(c), "lastEvent" to p.getString("lastEvent", null),
            "registered" to p.getBoolean("registered", false),
            "workName" to p.getString("workName", "工作地點"))
    }

    @SuppressLint("MissingPermission")
    fun captureHere(c: Context, kind: String): Boolean {
        if (kind !in setOf("home", "work") || ContextCompat.checkSelfPermission(c,
                Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) return false
        val loc = Tasks.await(LocationServices.getFusedLocationProviderClient(c)
            .getCurrentLocation(Priority.PRIORITY_HIGH_ACCURACY, null), 20, TimeUnit.SECONDS) ?: return false
        prefs(c).edit().putFloat("${kind}_lat", loc.latitude.toFloat()).putFloat("${kind}_lon", loc.longitude.toFloat()).commit()
        register(c)
        return true
    }

    fun setWorkName(c: Context, name: String) {
        if (Regex("^[\\u4e00-\\u9fffA-Za-z0-9 ]{1,8}$").matches(name.trim())) prefs(c).edit().putString("workName", name.trim()).commit()
    }

    fun enable(c: Context, hostUid: String, version: Int) {
        prefs(c).edit().putBoolean("enabled", true).putInt("version", version).putString("hostUid", hostUid).commit()
        register(c)
    }

    /** Local stop first, so nothing more is sent even if the server call fails. */
    fun disable(c: Context, forget: Boolean) {
        val editor = prefs(c).edit().putBoolean("enabled", false).remove("queue").putBoolean("registered", false)
        if (forget) editor.remove("home_lat").remove("home_lon").remove("work_lat").remove("work_lon")
        editor.commit()
        LocationServices.getGeofencingClient(c).removeGeofences(pending(c))
    }

    private fun pending(c: Context): PendingIntent = PendingIntent.getBroadcast(c, 4440,
        Intent(c, GeofenceReceiver::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)

    @SuppressLint("MissingPermission")
    fun register(c: Context) {
        val p = prefs(c)
        if (!p.getBoolean("enabled", false) || !hasBackground(c)) { p.edit().putBoolean("registered", false).commit(); return }
        val fences = listOf("home", "work").filter { p.contains("${it}_lat") }.map {
            Geofence.Builder().setRequestId(it)
                .setCircularRegion(p.getFloat("${it}_lat", 0f).toDouble(), p.getFloat("${it}_lon", 0f).toDouble(), RADIUS_M)
                .setExpirationDuration(Geofence.NEVER_EXPIRE)
                .setTransitionTypes(Geofence.GEOFENCE_TRANSITION_ENTER or Geofence.GEOFENCE_TRANSITION_EXIT)
                .setLoiteringDelay(60_000).build()
        }
        val client = LocationServices.getGeofencingClient(c)
        client.removeGeofences(pending(c))
        if (fences.isEmpty()) return
        client.addGeofences(GeofencingRequest.Builder().setInitialTrigger(0).addGeofences(fences).build(), pending(c))
            .addOnSuccessListener { p.edit().putBoolean("registered", true).commit() }
            .addOnFailureListener { p.edit().putBoolean("registered", false).commit() }
    }

    fun enqueue(c: Context, place: String, transition: String, at: Long) {
        val p = prefs(c)
        if (!p.getBoolean("enabled", false)) return
        val q = try { JSONArray(p.getString("queue", "[]")) } catch (_: Exception) { JSONArray() }
        q.put(JSONObject().put("place", place).put("transition", transition).put("at", at))
        val trimmed = JSONArray(); val start = (q.length() - 30).coerceAtLeast(0)
        for (i in start until q.length()) trimmed.put(q.get(i))
        p.edit().putString("queue", trimmed.toString())
            .putString("lastEvent", "${if (transition == "enter") "到達" else "離開"}${if (place == "home") "家" else p.getString("workName", "工作地點")}").commit()
        PlaceReportJob.schedule(c)
    }

    fun upload(c: Context) {
        val p = prefs(c)
        if (!p.getBoolean("enabled", false)) return
        val uid = FirebaseAuth.getInstance().currentUser?.uid ?: return
        if (uid != p.getString("hostUid", null)) return
        val q = try { JSONArray(p.getString("queue", "[]")) } catch (_: Exception) { JSONArray() }
        var sent = 0
        for (i in 0 until q.length()) {
            val e = q.getJSONObject(i)
            try {
                Tasks.await(FirebaseFunctions.getInstance("asia-east1").getHttpsCallable("reportPlaceEvent").call(mapOf(
                    "place" to e.getString("place"), "transition" to e.getString("transition"), "at" to e.getLong("at"),
                    "consentVersion" to p.getInt("version", 0))), 20, TimeUnit.SECONDS)
                sent++
            } catch (error: Exception) {
                val code = ((error as? ExecutionException)?.cause as? FirebaseFunctionsException)?.code
                if (code == FirebaseFunctionsException.Code.FAILED_PRECONDITION ||
                    code == FirebaseFunctionsException.Code.INVALID_ARGUMENT) { sent++; continue }
                break
            }
        }
        val rest = JSONArray(); for (i in sent until q.length()) rest.put(q.get(i))
        p.edit().putString("queue", rest.toString()).commit()
    }
}

class GeofenceReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val event = GeofencingEvent.fromIntent(intent) ?: return
        if (event.hasError()) return
        val transition = when (event.geofenceTransition) {
            Geofence.GEOFENCE_TRANSITION_ENTER -> "enter"
            Geofence.GEOFENCE_TRANSITION_EXIT -> "exit"
            else -> return
        }
        val at = event.triggeringLocation?.time ?: System.currentTimeMillis()
        event.triggeringGeofences?.forEach { PlaceAlerts.enqueue(context, it.requestId, transition, at) }
    }
}

class PlaceReportJob : JobService() {
    private val worker = Executors.newSingleThreadExecutor()
    override fun onStartJob(params: JobParameters): Boolean {
        worker.execute { try { PlaceAlerts.upload(applicationContext) } catch (_: Exception) {} finally { jobFinished(params, false) } }
        return true
    }
    override fun onStopJob(params: JobParameters) = true
    override fun onDestroy() { worker.shutdownNow(); super.onDestroy() }
    companion object {
        fun schedule(c: Context) {
            c.getSystemService(JobScheduler::class.java).schedule(JobInfo.Builder(4441, ComponentName(c, PlaceReportJob::class.java))
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY).setPersisted(true).build())
        }
    }
}
