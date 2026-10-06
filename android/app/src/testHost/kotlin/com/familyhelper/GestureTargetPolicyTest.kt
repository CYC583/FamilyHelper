// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GestureTargetPolicyTest {
    private val own = "com.familyhelper.host"

    @Test fun permitsMatchingOrdinaryApps() {
        assertTrue(allowedGestureTarget("com.google.android.youtube", "com.google.android.youtube", own))
        assertTrue(allowedGestureTarget("com.google.android.apps.nexuslauncher", "com.google.android.apps.nexuslauncher", own))
    }

    @Test fun rejectsSystemAndOwnWindows() {
        for (name in listOf(own, "android", "com.android.systemui", "com.google.android.permissioncontroller",
            "com.android.settings", "com.google.android.packageinstaller")) {
            assertFalse(name, allowedGestureTarget(name, name, own))
        }
    }

    @Test fun rejectsUnknownOrStaleActiveWindow() {
        assertFalse(allowedGestureTarget(null, "com.google.android.youtube", own))
        assertFalse(allowedGestureTarget("com.google.android.youtube", null, own))
        assertFalse(allowedGestureTarget("com.google.android.permissioncontroller", "com.google.android.youtube", own))
    }

    @Test fun dismissesSettingsOpenedByRecentRemoteGesture() {
        assertTrue(shouldDismissRemoteSettings("com.android.settings", 1_000L, 1_500L))
        assertFalse(shouldDismissRemoteSettings("com.android.settings", 1_000L, 6_001L))
        assertFalse(shouldDismissRemoteSettings("com.android.settings", 0L, 1_500L))
        assertFalse(shouldDismissRemoteSettings("com.google.android.apps.photos", 1_000L, 1_500L))
    }

    @Test fun recoversLauncherAfterDismissingRemoteSettings() {
        assertTrue(shouldRecoverLauncher("com.google.android.apps.nexuslauncher", "com.android.settings", true))
        assertFalse(shouldRecoverLauncher("com.google.android.permissioncontroller", "com.android.settings", true))
        assertFalse(shouldRecoverLauncher("com.google.android.apps.nexuslauncher", "com.android.settings", false))
    }
}
