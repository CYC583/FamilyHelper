// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper

/** Only screen on/off transitions and monotonic time are accepted here.
 * No foreground package, app title, or accessibility content is observed.
 * Process restart conservatively begins a new interval instead of guessing.
 */
class ScreenOnSession {
    private var beganAtMs: Long? = null

    fun screenOn(atMs: Long) { beganAtMs = atMs.coerceAtLeast(0L) }
    fun screenOff() { beganAtMs = null }
    fun continuousMs(nowMs: Long): Long = beganAtMs?.let { (nowMs - it).coerceAtLeast(0L) } ?: 0L
}
