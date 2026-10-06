// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.battery

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.SystemClock
import android.provider.Settings
import java.util.UUID

/** Reads the actual host phone at wake-up time. Never infers battery from a
 * delayed broadcast or from a family handset. No location/usage permission.
 */
object BatterySampler {
    // If a device hides BOOT_COUNT, a process restart resets the time window.
    // This can delay a family alert, but can never fabricate 30 minutes.
    private val processBootEpoch = "process-${UUID.randomUUID()}"

    fun read(context: Context): BatteryReading? {
        val sticky = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = sticky?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = sticky?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val percent = if (level >= 0 && scale > 0) (level * 100 / scale).coerceIn(0, 100) else {
            context.getSystemService(BatteryManager::class.java)
                ?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1
        }
        if (percent !in 0..100) return null
        val status = sticky?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
        val bootCount = Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT, -1)
        val bootEpoch = if (bootCount >= 0) "boot-$bootCount" else processBootEpoch
        return BatteryReading(percent, charging, System.currentTimeMillis(),
            SystemClock.elapsedRealtime(), bootEpoch)
    }
}
