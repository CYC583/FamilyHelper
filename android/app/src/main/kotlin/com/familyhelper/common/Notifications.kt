// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.common

import android.app.*
import android.content.Context
import android.content.Intent
import com.familyhelper.R

object Notifications {
    fun create(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("family_active", "協助與通話狀態", NotificationManager.IMPORTANCE_LOW))
        manager.createNotificationChannel(NotificationChannel("family_alerts", "家人求助通知", NotificationManager.IMPORTANCE_HIGH))
    }
    fun ongoing(context: Context, title: String, body: String, service: Class<out Service>): Notification {
        create(context)
        val open = context.packageManager.getLaunchIntentForPackage(context.packageName)!!
        val content = PendingIntent.getActivity(context, 1, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(context, service.name.hashCode(), Intent(context, service).setAction("STOP"), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(context, "family_active")
            .setSmallIcon(R.drawable.ic_stat_family).setContentTitle(title).setContentText(body)
            .setOngoing(true).setContentIntent(content)
            .addAction(Notification.Action.Builder(null, "停止", stop).build()).build()
    }
}
