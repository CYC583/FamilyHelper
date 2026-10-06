// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.battery

import org.junit.Assert.assertEquals
import org.junit.Test

class BatterySyncFailurePolicyTest {
    @Test fun staleAndEpisodeFailuresDropOnlyTheRejectedSample() {
        for (message in listOf(
            "舊電量樣本已失效",
            "相同序號的電量樣本不一致",
            "低電量 episode 已失效或識別碼不一致",
            "解除樣本的 episode 不一致",
        )) {
            assertEquals(BatteryFailureAction.DROP_SAMPLE,
                BatterySyncFailurePolicy.classify("FAILED_PRECONDITION", message))
        }
    }

    @Test fun onlyConsentOrHostRoleFailureStopsLocalSharing() {
        assertEquals(BatteryFailureAction.STOP_SHARE,
            BatterySyncFailurePolicy.classify("FAILED_PRECONDITION",
                "長輩未同意分享電量或同意版本已失效"))
        assertEquals(BatteryFailureAction.STOP_SHARE,
            BatterySyncFailurePolicy.classify("PERMISSION_DENIED", "裝置角色不符"))
    }

    @Test fun unknownPreconditionAndNetworkFailureRemainRetryable() {
        assertEquals(BatteryFailureAction.RETRY,
            BatterySyncFailurePolicy.classify("FAILED_PRECONDITION", "其他狀態暫時無法使用"))
        assertEquals(BatteryFailureAction.RETRY,
            BatterySyncFailurePolicy.classify("UNAVAILABLE", null))
    }

    @Test fun lateFailureFromOldConsentCannotStopNewApproval() {
        assertEquals(false, BatterySyncFailurePolicy.mayStopCurrentShare(1, 3, true))
        assertEquals(false, BatterySyncFailurePolicy.mayStopCurrentShare(3, 3, false))
        assertEquals(true, BatterySyncFailurePolicy.mayStopCurrentShare(3, 3, true))
    }
}
