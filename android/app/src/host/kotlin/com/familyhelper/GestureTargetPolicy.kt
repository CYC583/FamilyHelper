// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper

/** Deny remote gestures unless the current window and last window event agree.
 * Callers inspect only the active root's package identity, not its screen text. */
internal fun allowedGestureTarget(activePackage: String?, eventPackage: String?, ownPackage: String): Boolean {
    if (activePackage == null || activePackage != eventPackage || activePackage == ownPackage) return false
    if (activePackage == "android" || activePackage == "com.google.android.gms") return false
    return listOf("systemui", "permissioncontroller", "packageinstaller", "settings", "setupwizard")
        .none { activePackage.contains(it) }
}

/** A launcher tap can open Settings before the next gesture is checked.
 * Leave Settings immediately only when it followed a remote gesture. */
internal fun shouldDismissRemoteSettings(packageName: String?, remoteGestureAt: Long, now: Long): Boolean {
    return packageName?.contains("settings") == true && remoteGestureAt > 0 &&
        now - remoteGestureAt in 0L..5_000L
}

/** Android may omit the launcher's window-state event after GLOBAL_ACTION_HOME.
 * Recovery still requires the active root itself to belong to the launcher. */
internal fun shouldRecoverLauncher(activePackage: String?, eventPackage: String?, dismissedSettings: Boolean): Boolean {
    return dismissedSettings && activePackage?.contains("launcher") == true &&
        eventPackage?.contains("settings") == true
}
