// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.widget

object WidgetActions {
    private var pending: String? = null
    @Synchronized fun put(value: String) { if (value == "sos" || value == "call") pending = value }
    @Synchronized fun consume(): String? { val v = pending; pending = null; return v }
    @Synchronized fun hasAction() = pending != null
}
