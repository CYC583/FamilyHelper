// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.care

import org.junit.Assert.assertEquals
import org.junit.Test

class CareNotifierCodesTest {
    @Test fun replyButtonsNeverShareARequestCode() {
        for (key in listOf("2026-10-02:medicine:08:00", "2026-10-02:photo:16:00")) {
            val id = CareNotifier.reminderId(key)
            val codes = listOf("done", "later", "skip").map { CareNotifier.actionRequestCode(id, it) }
            assertEquals("done/skip once collided and recorded 吃了 as 略過", 3, codes.toSet().size)
        }
        val a = CareNotifier.actionRequestCode(CareNotifier.reminderId("x"), "skip")
        val b = CareNotifier.actionRequestCode(CareNotifier.reminderId("x") + 1, "done")
        assert(a != b)
    }
}
