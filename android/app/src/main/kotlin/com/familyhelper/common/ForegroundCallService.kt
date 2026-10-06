// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.common

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/** Camera and microphone FGS starts from the foreground Activity after runtime
 * permission, on BOTH flavors. It never starts from FCM or device boot. */
class ForegroundCallService : Service() {
    companion object {
        var ready: ((Throwable?) -> Unit)? = null
    }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "STOP") { NativeEvents.stop(); stopSelf(); return START_NOT_STICKY }
        try {
            val note = Notifications.ongoing(this, "FamilyHelper 通話中", "相機與麥克風使用中，點停止即可結束", javaClass)
            if (Build.VERSION.SDK_INT >= 30) startForeground(201, note, ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            else startForeground(201, note)
            ready?.invoke(null)
        } catch (e: Exception) { ready?.invoke(e); stopSelf() }
        finally { ready = null }
        return START_NOT_STICKY
    }
    override fun onTaskRemoved(rootIntent: Intent?) { NativeEvents.stop(); stopSelf() }
}
