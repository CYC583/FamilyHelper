// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.common

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

object NativeEvents {
    var channel: MethodChannel? = null
    var beforeStop: (() -> Unit)? = null
    fun stop() {
        // Native gate closes synchronously, before an asynchronous Dart callback.
        beforeStop?.invoke()
        Handler(Looper.getMainLooper()).post { channel?.invokeMethod("stopSession", null) }
    }
}
