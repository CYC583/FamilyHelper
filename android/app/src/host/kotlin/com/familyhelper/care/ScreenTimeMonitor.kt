// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.care

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import androidx.core.content.ContextCompat
import com.familyhelper.ScreenOnSession
import java.util.concurrent.Executors

/** Continuous screen time from ACTION_SCREEN_ON/OFF and the monotonic clock only.
 * No foreground app, title or accessibility content is read. If Android kills
 * the process the interval restarts on the next screen-on instead of guessing.
 */
object ScreenTimeMonitor {
    private val session = ScreenOnSession()
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var registered = false
    private var appContext: Context? = null
    private val check = Runnable { evaluate() }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_ON -> { session.screenOn(SystemClock.elapsedRealtime()); reschedule(context ?: return) }
                Intent.ACTION_SCREEN_OFF -> { session.screenOff(); main.removeCallbacks(check) }
            }
        }
    }

    @Synchronized fun start(context: Context) {
        val app = context.applicationContext
        appContext = app
        if (registered) return
        if (app.getSystemService(PowerManager::class.java).isInteractive) session.screenOn(SystemClock.elapsedRealtime())
        ContextCompat.registerReceiver(app, receiver, IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON); addAction(Intent.ACTION_SCREEN_OFF)
        }, ContextCompat.RECEIVER_NOT_EXPORTED)
        registered = true
        reschedule(app)
    }

    fun continuousMs(): Long = session.continuousMs(SystemClock.elapsedRealtime())

    fun reschedule(context: Context) {
        appContext = context.applicationContext
        main.removeCallbacks(check)
        val store = CareStore(context)
        if (!store.restEnabled()) return
        val untilThreshold = RestReminderPolicy.THRESHOLD_MS - continuousMs()
        val snooze = (store.restSnoozedUntil() ?: 0L) - System.currentTimeMillis()
        main.postDelayed(check, maxOf(untilThreshold, snooze, 60_000L))
    }

    private fun evaluate() {
        val context = appContext ?: return
        worker.execute {
            val store = CareStore(context)
            val now = System.currentTimeMillis()
            val decision = RestReminderPolicy.decide(now, continuousMs(), store.restEnabled(),
                store.restSnoozedUntil(), store.restLastRemindedAt())
            when (decision.action) {
                RestAction.REMIND_NOW -> if (CareNotifier.presentRest(context, store)) store.markRestReminded(now)
                RestAction.DEFERRED, RestAction.SNOOZED -> decision.atMs?.let { store.snoozeRest(it) }
                RestAction.NONE -> Unit
            }
            main.post { reschedule(context) }
        }
    }
}
