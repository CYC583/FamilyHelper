// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.reminders

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

/** Private host-only cache. Sharing and local speech are OFF until the person
 * holding this phone accepts the separate native reminder consent dialog.
 */
class AndroidReminderStore(context: Context) : ReminderLocalStore {
    private val prefs: SharedPreferences = context.applicationContext
        .getSharedPreferences("care_reminders_v1", Context.MODE_PRIVATE)

    override fun isEnabled() = prefs.getBoolean("enabled", false)
    override fun hostUid(): String? = prefs.getString("hostUid", null)

    /** 2 = the dialog that says family can see whether a reminder played. */
    fun disclosure(): Int = prefs.getInt("disclosure", 1)

    fun enableLocally(uid: String, disclosure: Int = 2): Boolean {
        if (uid.isBlank()) return false
        val editor = prefs.edit().putInt("disclosure", disclosure)
        if (hostUid() != uid) {
            editor.remove("settings").remove("acceptedKeys").remove("lastSyncedAt")
        }
        return editor.putString("hostUid", uid).putBoolean("enabled", true).commit()
    }

    fun stopLocally(): Boolean = prefs.edit()
        .putBoolean("enabled", false)
        .remove("hostUid")
        .remove("settings")
        .remove("acceptedKeys")
        .remove("lastSyncedAt")
        .commit()

    override fun cachedSettings(): ReminderSettings? {
        val raw = prefs.getString("settings", null) ?: return null
        return try {
            val json = JSONObject(raw)
            val entries = json.getJSONArray("items")
            val items = (0 until entries.length()).map { index ->
                val item = entries.getJSONObject(index)
                mapOf("type" to item.getString("type"), "time" to item.getString("time"),
                    "text" to item.getString("text"), "id" to item.optString("id", ""),
                    "repeat" to item.optString("repeat", "daily"),
                    "date" to item.optString("date", "").ifEmpty { null },
                    "voiceId" to item.optString("voiceId", "").ifEmpty { null },
                    "author" to item.optString("author", ""),
                    "createdBy" to item.optString("createdBy", "").ifEmpty { null },
                    "days" to item.optJSONArray("days")?.let { a -> (0 until a.length()).map { a.getInt(it) } },
                    "pausedUntil" to item.optString("pausedUntil", "").ifEmpty { null }).filterValues { it != null }
            }
            ReminderSettingsParser.parse(mapOf("version" to json.getInt("version"),
                "timezone" to json.getString("timezone"), "items" to items))
        } catch (_: Exception) {
            null
        }
    }

    override fun saveSettings(value: ReminderSettings) {
        require(value.isValid())
        val json = JSONObject().put("version", value.version)
            .put("timezone", value.timezone)
        val entries = JSONArray()
        value.items.forEach { item ->
            entries.put(JSONObject().put("type", item.type).put("time", item.time)
                .put("text", item.text).put("id", item.id).put("repeat", item.repeat)
                .put("date", item.date ?: "").put("voiceId", item.voiceId ?: "").put("author", item.author)
                .put("createdBy", item.authorUid ?: "")
                .put("days", item.days?.let { JSONArray(it) } ?: JSONArray())
                .put("pausedUntil", item.pausedUntil ?: ""))
        }
        json.put("items", entries)
        check(prefs.edit().putString("settings", json.toString())
            .putLong("lastSyncedAt", System.currentTimeMillis()).commit())
    }

    override fun acceptedKeys(): Set<String> =
        prefs.getStringSet("acceptedKeys", emptySet())?.toSet() ?: emptySet()

    override fun markAccepted(key: String) {
        val keys = (acceptedKeys() + key).sorted().takeLast(200).toSet()
        check(prefs.edit().putStringSet("acceptedKeys", keys).commit())
    }

    fun snapshot(): Map<String, Any?> = mapOf(
        "enabled" to isEnabled(),
        "disclosure" to disclosure(),
        "settingsVersion" to cachedSettings()?.version,
        "lastSyncedAt" to prefs.getLong("lastSyncedAt", 0).takeIf { it > 0 },
    )
}
