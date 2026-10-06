// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.battery

/** Firebase callable codes alone cannot distinguish revoked consent from a
 * stale queued sample: the already-deployed server uses FAILED_PRECONDITION
 * for both. Unknown messages stay retryable rather than silently stopping.
 */
enum class BatteryFailureAction { STOP_SHARE, DROP_SAMPLE, RETRY }

object BatterySyncFailurePolicy {
    private const val CONSENT_INVALID = "長輩未同意分享電量或同意版本已失效"
    private const val HOST_ROLE_INVALID = "裝置角色不符"
    private val obsoleteSamples = setOf(
        "舊電量樣本已失效",
        "相同序號的電量樣本不一致",
        "低電量 episode 已失效或識別碼不一致",
        "解除樣本的 episode 不一致",
    )

    fun classify(code: String?, message: String?): BatteryFailureAction = when {
        code == "PERMISSION_DENIED" && message == HOST_ROLE_INVALID -> BatteryFailureAction.STOP_SHARE
        code == "FAILED_PRECONDITION" && message == CONSENT_INVALID -> BatteryFailureAction.STOP_SHARE
        code == "FAILED_PRECONDITION" && message in obsoleteSamples -> BatteryFailureAction.DROP_SAMPLE
        else -> BatteryFailureAction.RETRY
    }

    fun mayStopCurrentShare(submittedVersion: Int, currentVersion: Int,
        currentlySharing: Boolean): Boolean =
        currentlySharing && submittedVersion > 0 && submittedVersion == currentVersion
}
