// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import com.familyhelper.R

abstract class FamilyWidget(private val action: String, private val layout: Int) : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) {
            val intent = Intent(context, WidgetActionActivity::class.java).putExtra("action", action)
            val pending = PendingIntent.getActivity(context, id, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val view = RemoteViews(context.packageName, layout).apply { setOnClickPendingIntent(R.id.widget_button, pending) }
            manager.updateAppWidget(id, view)
        }
    }
}
