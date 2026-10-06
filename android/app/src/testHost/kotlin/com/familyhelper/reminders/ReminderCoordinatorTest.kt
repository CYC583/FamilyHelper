// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.reminders

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class ReminderCoordinatorTest {
    private val now = Instant.parse("2026-10-02T02:05:00Z").toEpochMilli()
    private val item = ReminderItem("medicine", "10:00", "早藥")

    private class MemoryStore : ReminderLocalStore {
        var enabled = false
        var boundUid = "host-1"
        var settings: ReminderSettings? = null
        val accepted = mutableSetOf<String>()
        override fun isEnabled() = enabled
        override fun hostUid() = boundUid
        override fun cachedSettings() = settings
        override fun saveSettings(value: ReminderSettings) { settings = value }
        override fun acceptedKeys() = accepted.toSet()
        override fun markAccepted(key: String) { accepted.add(key) }
    }

    @Test fun disabledOrWrongHostNeverFetchesOrPresents() {
        val store = MemoryStore()
        var fetches = 0
        var presents = 0
        val coordinator = ReminderCoordinator(store,
            source = { fetches++; ReminderSettings(1, listOf(item)) },
            presenter = { presents++; true })
        assertEquals(ReminderRunStatus.disabled, coordinator.run("host-1", now))
        store.enabled = true
        assertEquals(ReminderRunStatus.identityMismatch, coordinator.run("other-host", now))
        assertEquals(0, fetches)
        assertEquals(0, presents)
    }

    @Test fun offlineUsesValidatedLocalPlanButOnlyMarksAfterNotificationAccepted() {
        val store = MemoryStore().apply {
            enabled = true
            settings = ReminderSettings(1, listOf(item))
        }
        var acceptedByAndroid = false
        val coordinator = ReminderCoordinator(store,
            source = { throw IllegalStateException("offline") },
            presenter = { acceptedByAndroid })
        assertEquals(ReminderRunStatus.cachedSettings, coordinator.run("host-1", now))
        assertTrue(store.accepted.isEmpty())
        acceptedByAndroid = true
        assertEquals(ReminderRunStatus.cachedSettings, coordinator.run("host-1", now))
        assertEquals(1, store.accepted.size)
        assertEquals(ReminderRunStatus.cachedSettings, coordinator.run("host-1", now))
        assertEquals(1, store.accepted.size)
    }

    @Test fun revokedWhileLoadingCannotPresentOrCacheFamilyText() {
        val store = MemoryStore().apply { enabled = true }
        var presents = 0
        val coordinator = ReminderCoordinator(store,
            source = { store.enabled = false; ReminderSettings(2, listOf(item)) },
            presenter = { presents++; true })
        assertEquals(ReminderRunStatus.disabled, coordinator.run("host-1", now))
        assertNull(store.settings)
        assertEquals(0, presents)
    }

    @Test fun badRemotePlanDoesNotOverwriteLastValidatedCache() {
        val store = MemoryStore().apply {
            enabled = true
            settings = ReminderSettings(2, listOf(item))
        }
        var presented = 0
        val coordinator = ReminderCoordinator(store,
            source = { ReminderSettings(3, listOf(ReminderItem("medicine", "10:00:00", "bad"))) },
            presenter = { presented++; true })
        assertEquals(ReminderRunStatus.cachedSettings, coordinator.run("host-1", now))
        assertEquals(2, store.settings?.version)
        assertEquals(1, presented)
    }

    @Test fun localStopDuringBatchPreventsTheSecondReminder() {
        val store = MemoryStore().apply { enabled = true }
        var presents = 0
        val coordinator = ReminderCoordinator(store,
            source = { ReminderSettings(1, listOf(item, ReminderItem("photo", "10:00", "拍照"))) },
            presenter = { presents++; store.enabled = false; true })
        assertEquals(ReminderRunStatus.disabled, coordinator.run("host-1", now))
        assertEquals(1, presents)
        assertTrue(store.accepted.isEmpty())
    }

    @Test fun lateOlderFamilySettingsCannotReplaceNewerCachedPlan() {
        val store = MemoryStore().apply {
            enabled = true
            settings = ReminderSettings(3, listOf(item))
        }
        val coordinator = ReminderCoordinator(store,
            source = { ReminderSettings(2, listOf(ReminderItem("photo", "10:00", "舊設定"))) },
            presenter = { true })
        assertEquals(ReminderRunStatus.cachedSettings, coordinator.run("host-1", now))
        assertEquals(3, store.settings?.version)
        assertEquals("medicine", store.settings?.items?.single()?.type)
    }
}
