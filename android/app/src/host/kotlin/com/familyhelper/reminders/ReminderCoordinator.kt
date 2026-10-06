// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.reminders

/** Remote family plan, cached only after host identity and schema checks. */
data class ReminderSettings(
    val version: Int,
    val items: List<ReminderItem>,
    val timezone: String = "Asia/Taipei",
)

interface ReminderLocalStore {
    fun isEnabled(): Boolean
    fun hostUid(): String?
    fun cachedSettings(): ReminderSettings?
    fun saveSettings(value: ReminderSettings)
    fun acceptedKeys(): Set<String>
    fun markAccepted(key: String)
}

enum class ReminderRunStatus {
    disabled,
    identityMismatch,
    noValidatedSettings,
    currentSettings,
    cachedSettings,
}

/** Pure orchestration. Android adapters supply auth-bound settings, local
 * consent/persistence, and notification acceptance. A successful presenter
 * means Android accepted the notification request, not that someone heard it.
 */
class ReminderCoordinator(
    private val store: ReminderLocalStore,
    private val source: () -> ReminderSettings?,
    private val presenter: (DueReminder) -> Boolean,
) {
    fun run(currentUid: String?, nowMs: Long): ReminderRunStatus {
        if (!store.isEnabled()) return ReminderRunStatus.disabled
        if (currentUid.isNullOrBlank() || currentUid != store.hostUid()) {
            return ReminderRunStatus.identityMismatch
        }
        val remote = try { source() } catch (_: Exception) { null }
        if (!store.isEnabled()) return ReminderRunStatus.disabled
        if (currentUid != store.hostUid()) return ReminderRunStatus.identityMismatch

        val previous = store.cachedSettings()
        val usableRemote = remote?.takeIf { it.isValid() && it.version >= (previous?.version ?: 0) }
        if (usableRemote != null) store.saveSettings(usableRemote)
        val plan = store.cachedSettings()?.takeIf { it.isValid() }
            ?: return ReminderRunStatus.noValidatedSettings
        for (due in ReminderSchedulePolicy.due(nowMs, plan.items, store.acceptedKeys())) {
            if (!store.isEnabled()) return ReminderRunStatus.disabled
            if (currentUid != store.hostUid()) return ReminderRunStatus.identityMismatch
            val accepted = try { presenter(due) } catch (_: Exception) { false }
            if (accepted && store.isEnabled() && currentUid == store.hostUid()) {
                store.markAccepted(due.key)
            }
        }
        return if (usableRemote != null) ReminderRunStatus.currentSettings
            else ReminderRunStatus.cachedSettings
    }
}

internal fun ReminderSettings.isValid(): Boolean {
    if (timezone != "Asia/Taipei" || version < 0 || items.size > 30) return false
    val validTime = Regex("^(?:[01][0-9]|2[0-3]):[0-5][0-9]$")
    val validId = Regex("^[a-z0-9-]{1,40}$")
    val allowed = setOf("medicine", "water", "rest", "photo", "custom")
    val keys = mutableSetOf<String>()
    for (item in items) {
        if (item.type !in allowed || !validTime.matches(item.time) ||
            item.text.length > 80 || item.text.any { it.code < 32 || it == '<' || it == '>' } ||
            (item.id.isNotEmpty() && !validId.matches(item.id)) ||
            (item.voiceId != null && !validId.matches(item.voiceId)) ||
            item.repeat !in setOf("daily", "once", "weekly") ||
            (item.repeat == "weekly" && (item.days.isNullOrEmpty() || item.days.any { it !in 1..7 })) ||
            (item.pausedUntil != null && !Regex("^\\d{4}-\\d{2}-\\d{2}$").matches(item.pausedUntil)) ||
            (item.repeat == "once" && (item.date == null || !Regex("^\\d{4}-\\d{2}-\\d{2}$").matches(item.date))) ||
            item.author.length > 24 ||
            !keys.add(if (item.id.isNotEmpty()) item.id else "${item.type}:${item.time}")) return false
    }
    return true
}
