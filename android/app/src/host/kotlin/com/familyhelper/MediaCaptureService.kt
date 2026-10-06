// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.*
import com.familyhelper.common.NativeEvents
import com.familyhelper.common.Notifications

/** Owns the foreground lifetime; flutter_webrtc owns the SINGLE MediaProjection
 * token and virtual display. Do not call getMediaProjection a second time here. */
class MediaCaptureService : Service() {
    companion object {
        var ready: ((Throwable?) -> Unit)? = null
    }
    private val handler = Handler(Looper.getMainLooper())
    private val watchdog = object : Runnable {
        override fun run() {
            if (ConsentGate.expired()) { ConsentGate.clear(); NativeEvents.stop(); stopSelf() }
            else handler.postDelayed(this, 1_000)
        }
    }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "STOP") { ConsentGate.clear(); NativeEvents.stop(); stopSelf(); return START_NOT_STICKY }
        try {
            val note = Notifications.ongoing(this, "家人正在看您的螢幕", "可隨時點停止，結束分享及遠端操作", javaClass)
            if (Build.VERSION.SDK_INT >= 29) startForeground(202, note, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
            else startForeground(202, note)
            handler.removeCallbacks(watchdog); handler.post(watchdog)
            ready?.invoke(null)
        } catch (e: Exception) { ConsentGate.clear(); ready?.invoke(e); stopSelf() }
        finally { ready = null }
        return START_NOT_STICKY
    }
    override fun onTaskRemoved(rootIntent: Intent?) { ConsentGate.clear(); NativeEvents.stop(); stopSelf() }
    override fun onDestroy() { handler.removeCallbacks(watchdog); ConsentGate.clear(); super.onDestroy() }
}
