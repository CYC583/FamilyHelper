// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper

import org.junit.Assert.assertEquals
import org.junit.Test

class ScreenOnSessionTest {
    @Test fun onlyScreenEventsMeasureContinuousViewing() {
        val session = ScreenOnSession()
        assertEquals(0L, session.continuousMs(1000))
        session.screenOn(1000)
        assertEquals(90 * 60 * 1000L, session.continuousMs(1000 + 90 * 60 * 1000L))
        session.screenOff()
        assertEquals(0L, session.continuousMs(99999999))
        session.screenOn(99999999)
        assertEquals(1L, session.continuousMs(100000000))
    }
}
