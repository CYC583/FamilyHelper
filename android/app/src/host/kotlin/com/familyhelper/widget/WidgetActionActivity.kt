// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.widget

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import com.familyhelper.MainActivity

/** Only an immutable widget PendingIntent may launch this non-exported entry.
 * Never trust a widget_action extra on the exported launcher Activity. */
class WidgetActionActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WidgetActions.put(intent.getStringExtra("action") ?: "")
        startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        finish()
    }
}
