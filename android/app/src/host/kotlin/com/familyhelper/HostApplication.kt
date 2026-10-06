// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper

import com.familyhelper.care.ScreenTimeMonitor
import io.flutter.app.FlutterApplication

/** Process-wide screen on/off listener for the optional rest reminder. */
class HostApplication : FlutterApplication() {
    override fun onCreate() {
        super.onCreate()
        ScreenTimeMonitor.start(this)
    }
}
