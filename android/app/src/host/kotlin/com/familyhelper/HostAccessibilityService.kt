// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.app.KeyguardManager
import android.content.Context
import android.graphics.Path
import android.graphics.Point
import android.os.SystemClock
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import com.familyhelper.common.NativeEvents

class HostAccessibilityService : AccessibilityService() {
    companion object {
        var instance: HostAccessibilityService? = null
            private set
    }
    private var topPackage: String? = null
    private var lastGesture = 0L
    private var lastRemoteGestureAt = 0L
    private var dismissedRemoteSettings = false
    private var pending = false
    override fun onServiceConnected() { instance = this }
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event?.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED &&
            event?.eventType != AccessibilityEvent.TYPE_WINDOWS_CHANGED) return
        val activePackage = rootInActiveWindow?.packageName?.toString()
        if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            topPackage = event.packageName?.toString()
        }
        if (shouldDismissRemoteSettings(activePackage, lastRemoteGestureAt, SystemClock.elapsedRealtime())) {
            lastRemoteGestureAt = 0L
            dismissedRemoteSettings = true
            performGlobalAction(GLOBAL_ACTION_HOME)
        }
    }
    override fun onInterrupt() { ConsentGate.clear(); NativeEvents.stop() }
    override fun onDestroy() { instance = null; ConsentGate.clear(); NativeEvents.stop(); super.onDestroy() }

    @Suppress("DEPRECATION")
    fun geometry(): Map<String, Int> {
        val display = (getSystemService(Context.WINDOW_SERVICE) as WindowManager).defaultDisplay
        val size = Point(); display.getRealSize(size)
        return mapOf("width" to size.x, "height" to size.y, "rotation" to display.rotation)
    }
    fun perform(data: Map<*, *>): Boolean {
        val id = data["sessionId"] as? String ?: return false
        val seq = (data["seq"] as? Number)?.toLong() ?: return false
        val type = data["type"] as? String ?: return false
        val keyguard = getSystemService(KeyguardManager::class.java)
        if (keyguard.isKeyguardLocked || pending || !ConsentGate.authorize(id, seq)) return false
        // No remote confirmation of consent, permissions, installation or
        // device administration. We never inspect node text or capture passwords.
        // A permission dialog can cover an ordinary app before the latest
        // window-state event arrives. Read only the active window's package,
        // then fail closed if it differs from the last event's package.
        val activePackage = rootInActiveWindow?.packageName?.toString()
        if (shouldRecoverLauncher(activePackage, topPackage, dismissedRemoteSettings)) {
            topPackage = activePackage
            dismissedRemoteSettings = false
        }
        if (!allowedGestureTarget(activePackage, topPackage, packageName)) return false
        val shape = geometry()
        if (listOf("width", "height", "rotation").any { (data[it] as? Number)?.toInt() != shape[it] }) return false
        val now = SystemClock.elapsedRealtime()
        if (now - lastGesture < 120) return false
        fun position(key: String): Float? {
            val v = (data[key] as? Number)?.toDouble() ?: return null
            return if (v.isFinite() && v in 0.0..1.0) v.toFloat() else null
        }
        val x = position("x") ?: return false
        val y = position("y") ?: return false
        val width = shape.getValue("width") - 1f; val height = shape.getValue("height") - 1f
        val path = Path().apply { moveTo(x * width, y * height) }
        val duration: Long = when (type) {
            "tap" -> 60
            "longPress" -> 700
            "swipe" -> {
                val x2 = position("x2") ?: return false
                val y2 = position("y2") ?: return false
                path.lineTo(x2 * width, y2 * height); 400
            }
            else -> return false
        }
        val gesture = GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(path, 0, duration)).build()
        pending = true; lastGesture = now
        val sent = dispatchGesture(gesture, object : GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription) { pending = false }
            override fun onCancelled(gestureDescription: GestureDescription) { pending = false }
        }, null)
        if (!sent) pending = false else lastRemoteGestureAt = now
        return sent
    }
}
