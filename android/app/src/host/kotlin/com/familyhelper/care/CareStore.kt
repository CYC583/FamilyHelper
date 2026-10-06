// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.care

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate

/** Private host-only companion state. Nothing here is uploaded unless the
 * matching companion item is enabled and mirrored from a server-accepted consent.
 */
class CareStore(context: Context) {
    private val prefs: SharedPreferences = context.applicationContext
        .getSharedPreferences("care_companion_v1", Context.MODE_PRIVATE)

    // ---- Local toggles (no data leaves the phone) ----
    fun restEnabled() = prefs.getBoolean("restEnabled", false)
    fun setRestEnabled(value: Boolean) = prefs.edit().putBoolean("restEnabled", value).commit()
    fun restSnoozedUntil(): Long? = prefs.getLong("restSnoozedUntil", 0).takeIf { it > 0 }
    fun restLastRemindedAt(): Long? = prefs.getLong("restLastRemindedAt", 0).takeIf { it > 0 }
    fun snoozeRest(untilMs: Long) = prefs.edit().putLong("restSnoozedUntil", untilMs).commit()
    fun markRestReminded(atMs: Long) = prefs.edit().putLong("restLastRemindedAt", atMs).commit()

    // ---- RTDB location (google-services carries no URL; FlutterFire passes it) ----
    fun saveDatabaseUrl(url: String) {
        if (Regex("^https://[a-z0-9-]+(\\.[a-z0-9-]+)*\\.(firebasedatabase\\.app|firebaseio\\.com)/?$").matches(url)) {
            prefs.edit().putString("databaseUrl", url).commit()
        }
    }
    fun databaseUrl(): String? = prefs.getString("databaseUrl", null)
    fun saveHostUid(uid: String) { if (uid.isNotBlank()) prefs.edit().putString("appHostUid", uid).commit() }
    fun appHostUid(): String? = prefs.getString("appHostUid", null)

    // ---- Family intro clips ("長輩，我是小明") and the weather rotation ----
    data class VoiceProfile(val uid: String, val name: String, val voiceId: String?, val joinWeather: Boolean)

    fun saveVoiceProfiles(raw: Map<*, *>?) {
        val json = JSONObject()
        raw?.forEach { (uid, value) ->
            val m = value as? Map<*, *> ?: return@forEach
            val id = (m["introVoiceId"] as? String)?.takeIf { Regex("^[a-z0-9-]{1,40}$").matches(it) }
            json.put(uid as? String ?: return@forEach, JSONObject().put("name", (m["name"] as? String ?: "家人").take(24))
                .put("voiceId", id ?: "").put("joinWeather", m["joinWeather"] == true && id != null))
        }
        prefs.edit().putString("voiceProfiles", json.toString()).commit()
    }

    fun voiceProfiles(): List<VoiceProfile> = try {
        val json = JSONObject(prefs.getString("voiceProfiles", "{}") ?: "{}")
        json.keys().asSequence().map { uid ->
            val m = json.getJSONObject(uid)
            VoiceProfile(uid, m.optString("name", "家人"), m.optString("voiceId").ifEmpty { null }, m.optBoolean("joinWeather"))
        }.toList()
    } catch (_: Exception) { emptyList() }

    fun introFor(uid: String?): String? = uid?.let { u -> voiceProfiles().firstOrNull { it.uid == u }?.voiceId }

    // ---- Reminder playback results (phone-side only; not proof she heard) ----
    @Synchronized fun recordDelivery(key: String, state: String, at: Long) {
        val log = try { JSONObject(prefs.getString("deliveries", "{}")) } catch (_: Exception) { JSONObject() }
        log.put(key, JSONObject().put("state", state).put("at", at))
        val cutoff = at - 2 * 86400_000L
        log.keys().asSequence().toList().forEach { k -> if (log.getJSONObject(k).optLong("at") < cutoff) log.remove(k) }
        val pending = try { JSONArray(prefs.getString("deliveryQueue", "[]")) } catch (_: Exception) { JSONArray() }
        pending.put(JSONObject().put("key", key).put("state", state).put("at", at))
        val trimmed = JSONArray(); val start = (pending.length() - 40).coerceAtLeast(0)
        for (i in start until pending.length()) trimmed.put(pending.get(i))
        prefs.edit().putString("deliveries", log.toString()).putString("deliveryQueue", trimmed.toString()).commit()
    }
    fun deliveries(): Map<String, String> = try {
        val log = JSONObject(prefs.getString("deliveries", "{}"))
        log.keys().asSequence().associateWith { log.getJSONObject(it).optString("state") }
    } catch (_: Exception) { emptyMap() }
    fun deliveryQueue(): JSONArray = try { JSONArray(prefs.getString("deliveryQueue", "[]")) } catch (_: Exception) { JSONArray() }
    @Synchronized fun dropDeliveries(count: Int) {
        val q = deliveryQueue(); val rest = JSONArray()
        for (i in count until q.length()) rest.put(q.get(i))
        prefs.edit().putString("deliveryQueue", rest.toString()).commit()
    }
    fun syncedPlanVersion() = prefs.getInt("syncedPlanVersion", -1)
    fun markSyncedPlan(v: Int) = prefs.edit().putInt("syncedPlanVersion", v).commit()

    fun lastAnnouncedAt(): Long = prefs.getLong("lastAnnouncedAt", 0)
    fun markAnnounced(at: Long) { if (at > lastAnnouncedAt()) prefs.edit().putLong("lastAnnouncedAt", at).commit() }

    // ---- Weather plan and pre-computed quotes (pushed by Flutter / RTDB) ----
    fun saveWeather(city: String, lat: Double, lon: Double, morningTime: String, version: Int) {
        if (city.isBlank() || city.length > 40 || lat !in -90.0..90.0 || lon !in -180.0..180.0 ||
            !Regex("^(?:[01][0-9]|2[0-3]):[0-5][0-9]$").matches(morningTime) ||
            version < prefs.getInt("weatherVersion", 0)) return
        prefs.edit().putString("weatherCity", city).putFloat("weatherLat", lat.toFloat())
            .putFloat("weatherLon", lon.toFloat()).putString("morningTime", morningTime)
            .putInt("weatherVersion", version).commit()
    }
    fun clearWeather() = prefs.edit().remove("weatherCity").remove("weatherLat").remove("weatherLon")
        .remove("morningTime").remove("weatherVersion").commit()
    fun weatherCity(): String? = prefs.getString("weatherCity", null)
    fun weatherLat() = prefs.getFloat("weatherLat", 0f).toDouble()
    fun weatherLon() = prefs.getFloat("weatherLon", 0f).toDouble()
    fun morningTime(): String? = prefs.getString("morningTime", null)

    fun saveQuotes(byDate: Map<String, String>) {
        val editor = prefs.edit()
        prefs.all.keys.filter { it.startsWith("quote:") }.forEach { editor.remove(it) }
        byDate.entries.take(40).forEach { (date, text) ->
            if (Regex("^\\d{4}-\\d{2}-\\d{2}$").matches(date) && text.isNotBlank() && text.length <= 80) {
                editor.putString("quote:$date", text.trim())
            }
        }
        editor.commit()
    }
    fun quoteFor(date: LocalDate): String? = prefs.getString("quote:$date", null)

    fun lastMorningKey(): String? = prefs.getString("lastMorningKey", null)
    fun markMorning(key: String, result: String) = prefs.edit().putString("lastMorningKey", key)
        .putString("morningResult", result).putLong("morningAt", System.currentTimeMillis()).commit()

    // ---- Reminder replies: local log for the UI and an upload queue ----
    fun responsesFor(date: String): Map<String, String> {
        val raw = prefs.getString("responses:$date", null) ?: return emptyMap()
        return try {
            val json = JSONObject(raw)
            json.keys().asSequence().associateWith { json.getString(it) }
        } catch (_: Exception) { emptyMap() }
    }

    @Synchronized fun recordResponse(date: String, type: String, time: String, response: String, atMs: Long) {
        val log = JSONObject(responsesFor(date)).put("$type:$time", response)
        val editor = prefs.edit().putString("responses:$date", log.toString())
        // Keep only a week of local reply logs.
        prefs.all.keys.filter { it.startsWith("responses:") && it.removePrefix("responses:") < LocalDate.parse(date).minusDays(7).toString() }
            .forEach { editor.remove(it) }
        if (companionItem("responses")) {
            val queue = queue()
            queue.put(JSONObject().put("date", date).put("type", type).put("time", time)
                .put("response", response).put("respondedAt", atMs))
            val trimmed = JSONArray()
            val start = (queue.length() - 50).coerceAtLeast(0)
            for (i in start until queue.length()) trimmed.put(queue.get(i))
            editor.putString("responseQueue", trimmed.toString())
        }
        editor.commit()
    }

    fun queue(): JSONArray = try { JSONArray(prefs.getString("responseQueue", "[]")) } catch (_: Exception) { JSONArray() }
    @Synchronized fun dropQueued(count: Int) {
        val queue = queue()
        val rest = JSONArray()
        for (i in count until queue.length()) rest.put(queue.get(i))
        prefs.edit().putString("responseQueue", rest.toString()).commit()
    }
    fun clearQueue() = prefs.edit().remove("responseQueue").commit()

    // ---- Snoozed reminders shown again by the next care run ----
    fun snoozes(): JSONArray = try { JSONArray(prefs.getString("snoozes", "[]")) } catch (_: Exception) { JSONArray() }
    @Synchronized fun addSnooze(key: String, type: String, time: String, text: String, dueAtMs: Long) {
        val next = JSONArray()
        val current = snoozes()
        for (i in 0 until current.length()) {
            val item = current.getJSONObject(i)
            if (item.optString("key") != key) next.put(item)
        }
        next.put(JSONObject().put("key", key).put("type", type).put("time", time).put("text", text).put("dueAt", dueAtMs))
        prefs.edit().putString("snoozes", next.toString()).commit()
    }
    @Synchronized fun removeSnooze(key: String) {
        val next = JSONArray()
        val current = snoozes()
        for (i in 0 until current.length()) {
            val item = current.getJSONObject(i)
            if (item.optString("key") != key) next.put(item)
        }
        prefs.edit().putString("snoozes", next.toString()).commit()
    }

    // ---- Last presentation results (shown honestly on the host) ----
    fun noteEvent(kind: String, message: String) = prefs.edit()
        .putString("event:$kind", message).putLong("eventAt:$kind", System.currentTimeMillis()).commit()

    // ---- Companion sharing mirror (set only after the server accepted it) ----
    fun setCompanionConsent(hostUid: String, version: Int, items: Map<String, Boolean>) {
        val editor = prefs.edit().putString("companionHost", hostUid).putInt("companionVersion", version)
        listOf("responses", "mood", "sound").forEach { editor.putBoolean("companion:$it", items[it] == true) }
        if (items["responses"] != true) editor.remove("responseQueue")
        editor.commit()
    }
    fun stopCompanionLocally() {
        val editor = prefs.edit().remove("companionVersion").remove("responseQueue").remove("soundSignature")
        listOf("responses", "mood", "sound").forEach { editor.putBoolean("companion:$it", false) }
        editor.commit()
    }
    fun companionHost(): String? = prefs.getString("companionHost", null)
    fun companionVersion(): Int = prefs.getInt("companionVersion", 0)
    fun companionItem(item: String) = companionVersion() > 0 && prefs.getBoolean("companion:$item", false)

    fun soundSignature(): String? = prefs.getString("soundSignature", null)
    fun soundReportedAt(): Long = prefs.getLong("soundReportedAt", 0)
    fun markSoundReported(signature: String, atMs: Long) = prefs.edit()
        .putString("soundSignature", signature).putLong("soundReportedAt", atMs).commit()

    fun snapshot(date: String): Map<String, Any?> = mapOf(
        "restEnabled" to restEnabled(),
        "weatherCity" to weatherCity(),
        "morningTime" to morningTime(),
        "morningResult" to prefs.getString("morningResult", null),
        "morningAt" to prefs.getLong("morningAt", 0).takeIf { it > 0 },
        "responses" to responsesFor(date),
        "queued" to queue().length(),
        "reminderEvent" to prefs.getString("event:reminder", null),
        "reminderEventAt" to prefs.getLong("eventAt:reminder", 0).takeIf { it > 0 },
        "restEvent" to prefs.getString("event:rest", null),
        "syncError" to prefs.getString("event:sync", null),
        "deliveries" to deliveries(),
        "companionVersion" to companionVersion(),
        "companionItems" to mapOf("responses" to companionItem("responses"),
            "mood" to companionItem("mood"), "sound" to companionItem("sound")),
    )
}
