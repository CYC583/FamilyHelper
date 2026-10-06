// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import com.familyhelper.common.Notifications

/** Optional, explicitly enabled standby. Android may still stop this service.
 * No camera, microphone, location or MediaProjection access while standing by. */
class ForegroundHelperService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "STOP") { stopSelf(); return START_NOT_STICKY }
        val note = Notifications.ongoing(this, "FamilyHelper 等待家人協助", "尚未分享螢幕；每次連線仍須您同意", javaClass)
        if (Build.VERSION.SDK_INT >= 34) startForeground(203, note, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        else startForeground(203, note)
        return START_NOT_STICKY
    }
}
