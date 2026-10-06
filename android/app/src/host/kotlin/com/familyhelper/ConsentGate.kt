// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper

import android.os.SystemClock

/** Volatile, in-memory consent. It is never restored from disk or notifications.
 * Only the local native dialog's positive button calls approve(). */
object ConsentGate {
    private var approved: String? = null
    private var approvedAt = 0L
    private var active: String? = null
    private var lastPeer = 0L
    private var peerSeen = false
    private var activatedAt = 0L
    private var sequence = -1L
    @Synchronized fun approve(id: String) { approved = id; approvedAt = SystemClock.elapsedRealtime() }
    @Synchronized fun cancelApproval(id: String) {
        if (approved == id) { approved = null; approvedAt = 0L }
    }
    @Synchronized fun activate(id: String): Boolean {
        if (approved != id || SystemClock.elapsedRealtime() - approvedAt > 120_000) return false
        active = id; activatedAt = SystemClock.elapsedRealtime(); lastPeer = activatedAt
        peerSeen = false; sequence = -1; approved = null
        return true
    }
    @Synchronized fun keepAlive(id: String): Boolean {
        if (active != id || expired()) return false
        lastPeer = SystemClock.elapsedRealtime(); peerSeen = true; return true
    }
    @Synchronized fun expired(): Boolean {
        val now = SystemClock.elapsedRealtime()
        return active == null || now - lastPeer > (if (peerSeen) 9_000 else 60_000) || now - activatedAt > 30 * 60_000
    }
    @Synchronized fun authorize(id: String, seq: Long): Boolean {
        if (active != id || !peerSeen || expired() || seq <= sequence) return false
        sequence = seq; return true
    }
    @Synchronized fun isActive() = active != null && !expired()
    @Synchronized fun clear() { active = null; approved = null; approvedAt = 0L; peerSeen = false; sequence = -1 }
}
