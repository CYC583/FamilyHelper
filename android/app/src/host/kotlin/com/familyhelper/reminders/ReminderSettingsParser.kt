// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.reminders

/** Strict boundary between RTDB's untyped snapshot and local spoken content.
 * Accepts the v1 `reminders` rows and the v2 `reminderPlan` rows.
 */
object ReminderSettingsParser {
    private val v2Keys = setOf("id", "type", "time", "text", "repeat", "date", "voiceId", "author",
        "createdBy", "updatedAt", "days", "pausedUntil", "editedBy")

    fun parse(raw: Any?): ReminderSettings? {
        if (raw == null) return ReminderSettings(0, emptyList())
        if (raw !is Map<*, *>) return null
        val number = raw["version"] as? Number ?: return null
        val value = number.toLong()
        if (value < 0 || value > Int.MAX_VALUE || number.toDouble() != value.toDouble()) return null
        if (raw["timezone"] != "Asia/Taipei") return null
        val entries = raw["items"] as? List<*> ?: (if (raw["items"] == null) emptyList<Any>() else return null)
        val items = entries.map { entry ->
            val map = entry as? Map<*, *> ?: return null
            if (map.keys.any { it !in v2Keys }) return null
            ReminderItem(
                map["type"] as? String ?: return null,
                map["time"] as? String ?: return null,
                (map["text"] as? String) ?: "",
                id = (map["id"] as? String) ?: "",
                repeat = (map["repeat"] as? String) ?: "daily",
                date = map["date"] as? String,
                voiceId = map["voiceId"] as? String,
                author = ((map["author"] as? String) ?: "").take(24),
                authorUid = (map["createdBy"] as? String)?.take(128),
                days = (map["days"] as? List<*>)?.map { (it as? Number)?.toInt() ?: return null },
                pausedUntil = map["pausedUntil"] as? String,
            )
        }
        return ReminderSettings(value.toInt(), items).takeIf { it.isValid() }
    }
}
