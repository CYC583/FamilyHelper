// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.health

import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.*
import androidx.health.connect.client.records.metadata.DataOrigin
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import androidx.lifecycle.lifecycleScope
import com.familyhelper.MainActivity
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.launch
import java.time.Duration
import java.time.Instant

/** Optional foreground reads, never a medical monitor. Samsung Health must
 * already have permission to WRITE these records to Health Connect. */
class HealthBridge(private val activity: MainActivity) {
    private val permissions = setOf(
        HealthPermission.getReadPermission(HeartRateRecord::class),
        HealthPermission.getReadPermission(OxygenSaturationRecord::class),
        HealthPermission.getReadPermission(SleepSessionRecord::class),
    )
    private var permissionResult: MethodChannel.Result? = null
    private val launcher = activity.registerForActivityResult(PermissionController.createRequestPermissionResultContract()) { granted ->
        permissionResult?.success(granted.containsAll(permissions)); permissionResult = null
    }
    private fun available() = HealthConnectClient.getSdkStatus(activity) == HealthConnectClient.SDK_AVAILABLE
    fun status(result: MethodChannel.Result) { result.success(available()) }
    fun requestPermission(result: MethodChannel.Result) {
        if (!available()) { result.error("HEALTH_UNAVAILABLE", "此手機的 Health Connect 尚未準備好", null); return }
        if (permissionResult != null) { result.error("BUSY", "正在等候健康權限", null); return }
        permissionResult = result; launcher.launch(permissions)
    }
    fun read(result: MethodChannel.Result) {
        if (!available()) { result.error("HEALTH_UNAVAILABLE", "Health Connect 尚未準備好", null); return }
        activity.lifecycleScope.launch {
            try {
                val client = HealthConnectClient.getOrCreate(activity)
                if (!client.permissionController.getGrantedPermissions().containsAll(permissions)) {
                    result.error("HEALTH_PERMISSION", "請先允許讀取健康資料", null); return@launch
                }
                val now = Instant.now()
                val range = TimeRangeFilter.between(now.minus(Duration.ofDays(2)), now)
                val origin = setOf(DataOrigin("com.sec.android.app.shealth"))
                val heart = client.readRecords(ReadRecordsRequest(HeartRateRecord::class, range,
                    dataOriginFilter = origin, ascendingOrder = false, pageSize = 1000)).records
                    .flatMap { it.samples }.maxByOrNull { it.time }
                val oxygen = client.readRecords(ReadRecordsRequest(OxygenSaturationRecord::class, range,
                    dataOriginFilter = origin, ascendingOrder = false, pageSize = 1000)).records.maxByOrNull { it.time }
                val sleep = client.readRecords(ReadRecordsRequest(SleepSessionRecord::class, range,
                    dataOriginFilter = origin, ascendingOrder = false, pageSize = 1000)).records.maxByOrNull { it.endTime }
                val out = mutableMapOf<String, Any>()
                heart?.let { out["heart"] = mapOf("value" to it.beatsPerMinute, "time" to it.time.toEpochMilli()) }
                oxygen?.let { out["oxygen"] = mapOf("value" to it.percentage.value, "time" to it.time.toEpochMilli()) }
                // Session duration, not medically inferred asleep time or sleep stage sum.
                sleep?.let { out["sleep"] = mapOf("value" to Duration.between(it.startTime, it.endTime).toMinutes() / 60.0, "time" to it.endTime.toEpochMilli()) }
                result.success(out)
            } catch (e: Exception) { result.error("HEALTH_READ", "讀取健康資料失敗：${e.message}", null) }
        }
    }
}
